#!/usr/bin/env bash
#
# ============================================================
# HiCloud Secure Storage Latest Upload
#
# Version : 1.3.10
#
# Purpose:
#   1. Validate NFS source
#   2. Verify source is stable before backup
#   3. Select daily/manual archive name
#   4. Pack + encrypt + upload with secure-storage-desktop-shell
#   5. Monitor local PACK and remote UPLOAD phases
#   6. Verify CLI exit status and "(RESULT) success"
#   7. Verify uploaded object exists in cloud list
#   8. Create local completion marker
#   9. Prevent duplicate/overlapping scheduled uploads
#
# Usage:
#   hicloud_latest_upload_v1.3.10.sh run
#   hicloud_latest_upload_v1.3.10.sh run testfile-20260917
#   hicloud_latest_upload_v1.3.10.sh check-source
#   hicloud_latest_upload_v1.3.10.sh list
#   hicloud_latest_upload_v1.3.10.sh status
#   hicloud_latest_upload_v1.3.10.sh version
#
# Notes:
#   - ArchiveName passed to HiCloud CLI does NOT include ".tar".
#   - Default archive name is YYYYMMDD.
#   - Existing cloud object is never overwritten automatically.
#   - v1.3.9 uploads each *.o3.signed file as an individual -TargetPath.
#   - This avoids embedding SOURCE_DIR (for example alldata/) as the
#     top-level directory in the outer tar archive.
#   - Non-*.o3.signed files such as app-shell.log and run.db are excluded.
#   - Duplicate basenames are rejected to avoid duplicate/ambiguous tar members.
#   - v1.3.10 captures packed archive size immediately from the PACK event.
# ============================================================

set -uo pipefail

VERSION="1.3.10"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

umask 077

CONFIG_FILE="${HICLOUD_UPLOAD_CONFIG:-/etc/hicloud-upload.conf}"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

[[ -r "$CONFIG_FILE" ]] ||
    die "cannot read config file: $CONFIG_FILE"

# shellcheck disable=SC1090
. "$CONFIG_FILE"

# ============================================================
# Defaults
# ============================================================

: "${S3S_BIN:=/ws/linux/usr/bin/secure-storage-desktop-shell}"

: "${SOURCE_DIR:=/alldata}"
: "${EXPECTED_NFS_SOURCE:=}"
: "${EXPECTED_MOUNT_TARGET:=/alldata}"

: "${TEMP_WORKSPACE:=/data_bk/HiCloudSecretS3_tmp/upload}"

: "${LOG_DIR:=/var/log/hicloud-upload}"
: "${STATE_DIR:=/var/lib/hicloud-upload}"

: "${ARCHIVE_MECHANISM:=tar}"
: "${ARCHIVE_PREFIX:=}"
: "${ARCHIVE_DATE_FORMAT:=%Y%m%d}"

: "${ENCRYPTION_ALGORITHM:=AES256}"

: "${LIST_RETRIES:=3}"
: "${LIST_RETRY_DELAY_SEC:=10}"

: "${UPLOAD_TIMEOUT_SEC:=43200}"
: "${MONITOR_INTERVAL_SEC:=30}"
: "${MONITOR_HEARTBEAT_SEC:=300}"

: "${SOURCE_STABILITY_INTERVAL_SEC:=30}"
: "${SOURCE_MIN_AGE_SEC:=300}"

# Log a non-recursive "ls -al --time-style=long-iso" view of SOURCE_DIR
# after the source stability check succeeds.
: "${LOG_SOURCE_FILE_LIST:=yes}"

: "${TEMP_SPACE_FACTOR_PERCENT:=125}"
: "${TEMP_SPACE_RESERVE_GB:=10}"

: "${POST_VERIFY_RETRIES:=6}"
: "${POST_VERIFY_DELAY_SEC:=10}"

: "${REQUIRE_RESULT_SUCCESS:=yes}"
: "${CLEANUP_TEMP_AFTER_SUCCESS:=yes}"
: "${PRESERVE_FAILED_TEMP:=yes}"

# ============================================================
# Validate configuration
# ============================================================

[[ -n "${ACCESS_KEY:-}" ]] ||
    die "ACCESS_KEY is not configured"

[[ -n "${SECRET_KEY:-}" ]] ||
    die "SECRET_KEY is not configured"

[[ "$ACCESS_KEY" != "CHANGE_ME" ]] ||
    die "ACCESS_KEY is still CHANGE_ME"

[[ "$SECRET_KEY" != "CHANGE_ME" ]] ||
    die "SECRET_KEY is still CHANGE_ME"

[[ -x "$S3S_BIN" ]] ||
    die "command not executable: $S3S_BIN"

[[ -n "${ENCRYPTION_KEY_FILE:-}" ]] ||
    die "ENCRYPTION_KEY_FILE is not configured"

[[ -r "$ENCRYPTION_KEY_FILE" ]] ||
    die "encryption key not readable: $ENCRYPTION_KEY_FILE"

[[ "$ARCHIVE_MECHANISM" == "tar" ||
   "$ARCHIVE_MECHANISM" == "tar.gz" ]] ||
    die "unsupported ARCHIVE_MECHANISM=$ARCHIVE_MECHANISM"

[[ "$ENCRYPTION_ALGORITHM" == "AES256" ||
   "$ENCRYPTION_ALGORITHM" == "C20P1305" ]] ||
    die "unsupported ENCRYPTION_ALGORITHM=$ENCRYPTION_ALGORITHM"

for cmd in \
    awk date df find findmnt flock grep head ls mkdir mv rm sed setsid \
    sort stat tee touch tr wc
do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "required command not found: $cmd"
done

# ============================================================
# Prepare runtime directories
# ============================================================

mkdir -p "$TEMP_WORKSPACE" "$LOG_DIR" "$STATE_DIR"

chmod 700 "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

RUN_DATE="$(date '+%Y%m%d')"
RUN_LOG="${LOG_DIR}/hicloud-upload-${RUN_DATE}.log"

touch "$RUN_LOG"
chmod 600 "$RUN_LOG"

log()
{
    local level="$1"
    shift

    printf '%s [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$level" \
        "$*" | tee -a "$RUN_LOG"
}

# ============================================================
# Globals
# ============================================================

LIST_OUTPUT=""
CLOUD_FILES=""

UPLOAD_PID=""
CURRENT_RUN_TEMP_DIR=""
CURRENT_TOOL_LOG=""
CURRENT_PHASE_FILE=""
CURRENT_OUTPUT_DONE_FILE=""
CURRENT_PACKED_SIZE_FILE=""

SOURCE_FILE_COUNT=0
SOURCE_TOTAL_BYTES=0
SOURCE_NEWEST_EPOCH=0

# v1.3.9 exact upload target set. Each entry becomes one -TargetPath.
UPLOAD_TARGETS=()
UPLOAD_TARGET_COUNT=0
UPLOAD_TARGET_BYTES=0

# ============================================================
# Lock
# ============================================================

LOCK_FILE="/run/lock/hicloud-latest-upload.lock"

acquire_lock()
{
    mkdir -p "$(dirname "$LOCK_FILE")"

    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        log INFO "another upload process is already running; exit"
        return 1
    fi

    return 0
}

# ============================================================
# Signal handling
# ============================================================

cleanup_signal()
{
    local signal_name="${1:-UNKNOWN}"

    log WARNING "received termination signal: $signal_name"

    if [[ -n "${UPLOAD_PID:-}" ]] &&
       kill -0 "$UPLOAD_PID" 2>/dev/null; then

        log WARNING \
            "terminating upload process group PID=$UPLOAD_PID"

        kill -TERM -- "-${UPLOAD_PID}" 2>/dev/null || true

        sleep 5

        if kill -0 "$UPLOAD_PID" 2>/dev/null; then
            log WARNING \
                "upload process still running; sending SIGKILL"

            kill -KILL -- "-${UPLOAD_PID}" 2>/dev/null || true
        fi
    fi

    if [[ -n "${CURRENT_RUN_TEMP_DIR:-}" &&
          -d "$CURRENT_RUN_TEMP_DIR" ]]; then

        log WARNING \
            "temporary run directory preserved after signal: $CURRENT_RUN_TEMP_DIR"
    fi

    exit 130
}

trap 'cleanup_signal INT' INT
trap 'cleanup_signal TERM' TERM
trap 'cleanup_signal HUP' HUP

# ============================================================
# Helpers
# ============================================================

get_file_size()
{
    local file="$1"

    if [[ -f "$file" ]]; then
        stat -c '%s' "$file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

format_bytes()
{
    local bytes="${1:-0}"

    awk -v b="$bytes" '
        BEGIN {
            if (b >= 1099511627776)
                printf "%.2fTiB", b / 1099511627776;
            else if (b >= 1073741824)
                printf "%.2fGiB", b / 1073741824;
            else if (b >= 1048576)
                printf "%.2fMiB", b / 1048576;
            else if (b >= 1024)
                printf "%.2fKiB", b / 1024;
            else
                printf "%.0fB", b;
        }
    '
}

yes_value()
{
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}

normalize_archive_name()
{
    local requested="${1:-}"
    local name

    if [[ -n "$requested" ]]; then
        name="$requested"
    else
        name="${ARCHIVE_PREFIX}$(date +"$ARCHIVE_DATE_FORMAT")"
    fi

    name="${name%.tar}"
    name="${name%.tar.gz}"

    if [[ -z "$name" ]]; then
        return 1
    fi

    # Deliberately restrictive: no slash, whitespace, shell metacharacters.
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        return 1
    fi

    printf '%s\n' "$name"
}

archive_extension()
{
    case "$ARCHIVE_MECHANISM" in
        tar)    printf '.tar\n' ;;
        tar.gz) printf '.tar.gz\n' ;;
    esac
}

# ============================================================
# NFS source validation
# ============================================================

validate_source_mount()
{
    local source_info
    local mounted_source
    local fstype
    local mount_target

    [[ -d "$SOURCE_DIR" ]] || {
        log ERROR "source directory does not exist: $SOURCE_DIR"
        return 1
    }

    source_info="$(
        findmnt -rn -T "$SOURCE_DIR" -o SOURCE,FSTYPE,TARGET 2>/dev/null
    )"

    [[ -n "$source_info" ]] || {
        log ERROR "cannot determine mount for source: $SOURCE_DIR"
        return 1
    }

    read -r mounted_source fstype mount_target <<< "$source_info"

    case "$fstype" in
        nfs|nfs4) ;;
        *)
            log ERROR \
                "source is not on NFS: source=$SOURCE_DIR fstype=$fstype mounted_source=$mounted_source target=$mount_target"
            return 1
            ;;
    esac

    if [[ -n "$EXPECTED_NFS_SOURCE" &&
          "$mounted_source" != "$EXPECTED_NFS_SOURCE" ]]; then

        log ERROR \
            "unexpected NFS source: expected=$EXPECTED_NFS_SOURCE actual=$mounted_source"

        return 1
    fi

    if [[ -n "$EXPECTED_MOUNT_TARGET" &&
          "$mount_target" != "$EXPECTED_MOUNT_TARGET" ]]; then

        log ERROR \
            "unexpected NFS mount target: expected=$EXPECTED_MOUNT_TARGET actual=$mount_target"

        return 1
    fi

    [[ -r "$SOURCE_DIR" && -x "$SOURCE_DIR" ]] || {
        log ERROR "source directory is not readable/searchable: $SOURCE_DIR"
        return 1
    }

    log INFO \
        "NFS source OK: source=$mounted_source target=$mount_target fstype=$fstype"

    return 0
}

# ============================================================
# Source snapshot / stability
# ============================================================

source_snapshot()
{
    local tmp
    local rc
    local result

    tmp="$(mktemp "${STATE_DIR}/.source-snapshot.XXXXXX")" ||
        return 1

    if find "$SOURCE_DIR" \
        -xdev \
        -type f \
        -name '*.o3.signed' \
        -printf '%s %T@\n' \
        > "$tmp" 2>> "$RUN_LOG"
    then
        rc=0
    else
        rc=$?
    fi

    if (( rc != 0 )); then
        rm -f "$tmp"
        return "$rc"
    fi

    result="$(
        awk '
            {
                count++;
                bytes += $1;

                t = int($2);

                if (t > newest)
                    newest = t;
            }

            END {
                printf "%d %.0f %.0f\n",
                    count + 0,
                    bytes + 0,
                    newest + 0;
            }
        ' "$tmp"
    )"

    rm -f "$tmp"

    printf '%s\n' "$result"
}

verify_source_stable()
{
    local snap1
    local snap2

    local count1 bytes1 newest1
    local count2 bytes2 newest2

    local now
    local age

    log INFO "checking source snapshot: $SOURCE_DIR"

    snap1="$(source_snapshot)" || {
        log ERROR "failed to scan source directory"
        return 1
    }

    read -r count1 bytes1 newest1 <<< "$snap1"

    if (( count1 <= 0 )); then
        log ERROR "source contains no *.o3.signed regular files: $SOURCE_DIR"
        return 1
    fi

    now="$(date +%s)"

    if (( newest1 > 0 )); then
        age=$((now - newest1))

        if (( age < SOURCE_MIN_AGE_SEC )); then
            log ERROR \
                "source is too recent/possibly still changing: newest_age=${age}s required_age=${SOURCE_MIN_AGE_SEC}s"
            return 1
        fi
    fi

    log INFO \
        "source snapshot #1: files=$count1 bytes=$bytes1 ($(format_bytes "$bytes1")) newest_epoch=$newest1"

    if (( SOURCE_STABILITY_INTERVAL_SEC > 0 )); then
        log INFO \
            "waiting ${SOURCE_STABILITY_INTERVAL_SEC}s for source stability check"

        sleep "$SOURCE_STABILITY_INTERVAL_SEC"
    fi

    snap2="$(source_snapshot)" || {
        log ERROR "failed to re-scan source directory"
        return 1
    }

    read -r count2 bytes2 newest2 <<< "$snap2"

    log INFO \
        "source snapshot #2: files=$count2 bytes=$bytes2 ($(format_bytes "$bytes2")) newest_epoch=$newest2"

    if [[ "$count1" != "$count2" ||
          "$bytes1" != "$bytes2" ||
          "$newest1" != "$newest2" ]]; then

        log ERROR \
            "source changed during stability window; upload aborted"

        log ERROR \
            "before: files=$count1 bytes=$bytes1 newest=$newest1"

        log ERROR \
            "after : files=$count2 bytes=$bytes2 newest=$newest2"

        return 1
    fi

    SOURCE_FILE_COUNT="$count2"
    SOURCE_TOTAL_BYTES="$bytes2"
    SOURCE_NEWEST_EPOCH="$newest2"

    log INFO \
        "source stability check successful: files=$SOURCE_FILE_COUNT bytes=$SOURCE_TOTAL_BYTES ($(format_bytes "$SOURCE_TOTAL_BYTES"))"

    return 0
}

# ============================================================
# v1.3.9 exact upload target discovery
#
# Every regular *.o3.signed file below SOURCE_DIR becomes one
# separate vendor CLI argument:
#
#   -TargetPath /alldata/file1.o3.signed
#   -TargetPath /alldata/file2.o3.signed
#
# The vendor CLI then stores the basename at the outer tar root,
# avoiding an "alldata/" top-level directory.
#
# Safety / consistency controls:
#   * regular files only
#   * same filesystem (-xdev)
#   * *.o3.signed only
#   * deterministic LC_ALL=C sort order
#   * restrictive basename compatible with recovery verifier
#   * reject duplicate basenames (important if nested dirs exist)
#   * selected count/bytes must match the stability snapshot
# ============================================================

build_upload_targets()
{
    local tmp
    local file
    local base
    local size
    local count=0
    local bytes=0
    local rc=0
    local -A seen_basenames=()

    UPLOAD_TARGETS=()
    UPLOAD_TARGET_COUNT=0
    UPLOAD_TARGET_BYTES=0

    tmp="$(mktemp "${STATE_DIR}/.upload-targets.XXXXXX")" || {
        log ERROR "cannot create upload target manifest"
        return 1
    }

    if find "$SOURCE_DIR" \
        -xdev \
        -type f \
        -name '*.o3.signed' \
        -print0 2>>"$RUN_LOG" | \
        LC_ALL=C sort -z > "$tmp"
    then
        :
    else
        rc=$?
        rm -f -- "$tmp"
        log ERROR "failed to enumerate *.o3.signed upload targets rc=$rc source=$SOURCE_DIR"
        return "$rc"
    fi

    while IFS= read -r -d '' file; do
        [[ -n "$file" ]] || continue

        # The file can disappear/change between the stability snapshot and
        # target construction; require it to still be a regular readable file.
        [[ -f "$file" && -r "$file" ]] || {
            log ERROR "upload target is no longer a readable regular file: $file"
            rm -f -- "$tmp"
            UPLOAD_TARGETS=()
            return 1
        }

        base="${file##*/}"

        # Keep outer member names compatible with recovery path validation.
        if [[ ! "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.o3\.signed$ ]]; then
            log ERROR "unsafe/unsupported upload target basename: $base path=$file"
            rm -f -- "$tmp"
            UPLOAD_TARGETS=()
            return 1
        fi

        # The vendor CLI flattens individual file targets to the tar root.
        # Duplicate basenames would therefore create duplicate tar members.
        if [[ -n "${seen_basenames[$base]+x}" ]]; then
            log ERROR "duplicate upload target basename detected: basename=$base first=${seen_basenames[$base]} second=$file"
            rm -f -- "$tmp"
            UPLOAD_TARGETS=()
            return 1
        fi
        seen_basenames["$base"]="$file"

        size="$(stat -c '%s' -- "$file" 2>/dev/null)"
        [[ "$size" =~ ^[0-9]+$ ]] || {
            log ERROR "cannot determine upload target size: $file"
            rm -f -- "$tmp"
            UPLOAD_TARGETS=()
            return 1
        }

        UPLOAD_TARGETS+=("$file")
        count=$((count + 1))
        bytes=$((bytes + size))
    done < "$tmp"

    rm -f -- "$tmp"

    if (( count <= 0 )); then
        log ERROR "no *.o3.signed upload targets found: $SOURCE_DIR"
        return 1
    fi

    UPLOAD_TARGET_COUNT="$count"
    UPLOAD_TARGET_BYTES="$bytes"

    # Ensure the exact target set still agrees with the completed stability
    # snapshot before invoking the vendor uploader.
    if (( UPLOAD_TARGET_COUNT != SOURCE_FILE_COUNT ||
          UPLOAD_TARGET_BYTES != SOURCE_TOTAL_BYTES )); then
        log ERROR "upload target set changed after stability check; upload aborted"
        log ERROR "stable_snapshot: files=$SOURCE_FILE_COUNT bytes=$SOURCE_TOTAL_BYTES"
        log ERROR "target_manifest: files=$UPLOAD_TARGET_COUNT bytes=$UPLOAD_TARGET_BYTES"
        UPLOAD_TARGETS=()
        return 1
    fi

    log INFO "upload target manifest ready: files=$UPLOAD_TARGET_COUNT bytes=$UPLOAD_TARGET_BYTES ($(format_bytes "$UPLOAD_TARGET_BYTES"))"
    return 0
}

log_upload_targets()
{
    local file
    local size

    log INFO "============================================================"
    log INFO "UPLOAD TARGET LIST BEGIN: individual *.o3.signed files"

    for file in "${UPLOAD_TARGETS[@]}"; do
        size="$(stat -c '%s' -- "$file" 2>/dev/null || echo 0)"
        printf '%s [TARGET] size=%s path=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$size" \
            "$file" | tee -a "$RUN_LOG"
    done

    log INFO "UPLOAD TARGET LIST END: files=$UPLOAD_TARGET_COUNT bytes=$UPLOAD_TARGET_BYTES"
    log INFO "============================================================"
    return 0
}

# ============================================================
# Source file listing for audit/log review
#
# Equivalent view:
#
#   ls -al --time-style=long-iso /alldata
#
# This is intentionally NON-recursive. The recursive source
# *.o3.signed statistics are already captured by source_snapshot().
# ============================================================

log_source_file_list()
{
    local line
    local rc

    if ! yes_value "$LOG_SOURCE_FILE_LIST"; then

        log INFO \
            "source file listing disabled by configuration"

        return 0
    fi

    [[ -d "$SOURCE_DIR" ]] || {

        log ERROR \
            "cannot list source files; directory does not exist: $SOURCE_DIR"

        return 1
    }

    log INFO \
        "============================================================"

    log INFO \
        "SOURCE FILE LIST BEGIN: ls -al --time-style=long-iso $SOURCE_DIR"

    #
    # Keep the familiar ls -al format, but prefix each row so
    # audit logs can be searched with:
    #
    #   grep '\[SOURCE\]' <logfile>
    #
    while IFS= read -r line || [[ -n "$line" ]]; do

        printf '%s [SOURCE] %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$line" |
            tee -a "$RUN_LOG"

    done < <(
        LC_ALL=C ls -al \
            --time-style=long-iso \
            -- "$SOURCE_DIR" 2>&1
    )

    #
    # Re-run only as a quiet status check. This does not alter
    # files and avoids treating a listing failure as success.
    #
    LC_ALL=C ls -al \
        --time-style=long-iso \
        -- "$SOURCE_DIR" \
        >/dev/null 2>&1

    rc=$?

    if (( rc != 0 )); then

        log ERROR \
            "source file listing failed rc=$rc source=$SOURCE_DIR"

        return "$rc"
    fi

    log INFO \
        "SOURCE FILE LIST END: source=$SOURCE_DIR"

    log INFO \
        "============================================================"

    return 0
}

# ============================================================
# Temporary filesystem free-space check
# ============================================================

check_temp_space()
{
    local free_kb
    local source_kb
    local required_kb
    local reserve_kb

    free_kb="$(
        df -Pk "$TEMP_WORKSPACE" 2>/dev/null |
        awk 'NR == 2 {print $4}'
    )"

    [[ "$free_kb" =~ ^[0-9]+$ ]] || {
        log ERROR \
            "cannot determine free space for temporary workspace: $TEMP_WORKSPACE"
        return 1
    }

    [[ "$TEMP_SPACE_FACTOR_PERCENT" =~ ^[0-9]+$ ]] || {
        log ERROR \
            "invalid TEMP_SPACE_FACTOR_PERCENT=$TEMP_SPACE_FACTOR_PERCENT"
        return 1
    }

    [[ "$TEMP_SPACE_RESERVE_GB" =~ ^[0-9]+$ ]] || {
        log ERROR \
            "invalid TEMP_SPACE_RESERVE_GB=$TEMP_SPACE_RESERVE_GB"
        return 1
    }

    source_kb=$(( (SOURCE_TOTAL_BYTES + 1023) / 1024 ))
    reserve_kb=$(( TEMP_SPACE_RESERVE_GB * 1024 * 1024 ))

    required_kb=$(( source_kb * TEMP_SPACE_FACTOR_PERCENT / 100 + reserve_kb ))

    if (( free_kb < required_kb )); then

        log ERROR \
            "insufficient temporary space: free=$((free_kb / 1024 / 1024))GB required=$((required_kb / 1024 / 1024))GB source=$(format_bytes "$SOURCE_TOTAL_BYTES")"

        return 1
    fi

    log INFO \
        "temporary space OK: free=$((free_kb / 1024 / 1024))GB required=$((required_kb / 1024 / 1024))GB source=$(format_bytes "$SOURCE_TOTAL_BYTES")"

    return 0
}

# ============================================================
# Cloud list
# ============================================================

fetch_cloud_list()
{
    local attempt
    local rc
    local output

    LIST_OUTPUT=""
    CLOUD_FILES=""

    for ((attempt=1; attempt<=LIST_RETRIES; attempt++)); do

        log INFO \
            "requesting cloud file list attempt=${attempt}/${LIST_RETRIES}"

        output="$(
            "$S3S_BIN" list \
                -AccessKey "$ACCESS_KEY" \
                -SecretKey "$SECRET_KEY" \
                2>&1
        )"

        rc=$?

        # list output does not normally contain encryption key data.
        printf '%s\n' "$output" >> "$RUN_LOG"

        if (( rc == 0 )); then

            LIST_OUTPUT="$output"

            CLOUD_FILES="$(
                printf '%s\n' "$LIST_OUTPUT" |
                sed -nE \
                    's/^[[:space:]]*\[[0-9]+\][[:space:]]+file:[[:space:]]*(.+)[[:space:]]*$/\1/p'
            )"

            log INFO \
                "cloud list command completed successfully"

            return 0
        fi

        log WARNING \
            "cloud list failed rc=$rc attempt=$attempt"

        if (( attempt < LIST_RETRIES )); then
            sleep "$LIST_RETRY_DELAY_SEC"
        fi
    done

    log ERROR \
        "cloud list failed after ${LIST_RETRIES} attempts"

    return 1
}

cloud_object_exists()
{
    local archive_file="$1"

    printf '%s\n' "$CLOUD_FILES" |
        grep -F -x -q -- "$archive_file"
}

verify_cloud_object()
{
    local archive_file="$1"

    local attempt

    for ((attempt=1; attempt<=POST_VERIFY_RETRIES; attempt++)); do

        log INFO \
            "post-upload cloud verification attempt=${attempt}/${POST_VERIFY_RETRIES} archive=$archive_file"

        if fetch_cloud_list && cloud_object_exists "$archive_file"; then

            log INFO \
                "post-upload cloud verification SUCCESS: archive=$archive_file"

            return 0
        fi

        if (( attempt < POST_VERIFY_RETRIES )); then
            sleep "$POST_VERIFY_DELAY_SEC"
        fi
    done

    log ERROR \
        "post-upload cloud verification FAILED: archive=$archive_file"

    return 1
}

# ============================================================
# Upload child output handler
#
# IMPORTANT:
# secure-storage-desktop-shell prints "EncryptionKey: ...".
# Do not persist that value in console/log files.
# ============================================================

process_upload_output()
{
    local line
    local safe_line
    local packed_file
    local packed_size

    while IFS= read -r line || [[ -n "$line" ]]; do

        safe_line="$line"

        case "$line" in
            EncryptionKey:*)
                safe_line="EncryptionKey: [REDACTED]"
                ;;
        esac

        case "$line" in
            *"(PATH-PARSE)"*)
                printf 'PATH_PARSE\n' > "$CURRENT_PHASE_FILE"
                ;;

            *"(PACK) packed files in outputPackFile:"*)
                printf 'PACKED\n' > "$CURRENT_PHASE_FILE"

                # v1.3.10: the vendor CLI may upload and remove a small
                # temporary archive before the 30-second monitor loop polls it.
                # Capture its size immediately while the PACK output line is
                # being consumed. The process-substitution handler writes the
                # value to a per-run state file for the parent shell.
                packed_file="${line#*outputPackFile: }"
                packed_size="$(stat -c '%s' -- "$packed_file" 2>/dev/null || echo 0)"

                if [[ "$packed_size" =~ ^[0-9]+$ ]] &&
                   (( packed_size > 0 )); then
                    printf '%s\n' "$packed_size" > "$CURRENT_PACKED_SIZE_FILE"
                fi
                ;;

            *"(UPLOAD) begin-progress:"*)
                printf 'UPLOAD\n' > "$CURRENT_PHASE_FILE"
                ;;

            *"----> SUCCESS"*)
                printf 'UPLOAD_SUCCESS\n' > "$CURRENT_PHASE_FILE"
                ;;

            *"(RESULT) success"*)
                printf 'RESULT_SUCCESS\n' > "$CURRENT_PHASE_FILE"
                ;;
        esac

        printf '%s\n' "$safe_line" |
            tee -a "$RUN_LOG" "$CURRENT_TOOL_LOG"

    done

    touch "$CURRENT_OUTPUT_DONE_FILE"
}

# ============================================================
# Marker
# ============================================================

read_marker_value()
{
    local marker="$1"
    local key="$2"

    awk -v key="$key" '
        index($0, key "=") == 1 {
            sub("^[^=]*=", "")
            print
            exit
        }
    ' "$marker" 2>/dev/null
}

create_done_marker()
{
    local marker="$1"
    local archive_file="$2"
    local archive_size="$3"
    local elapsed="$4"

    {
        echo "status=SUCCESS"
        echo "version=$VERSION"
        echo "archive=$archive_file"
        echo "cloud_verify=SUCCESS"
        echo "source_dir=$SOURCE_DIR"
        echo "source_files=$SOURCE_FILE_COUNT"
        echo "source_bytes=$SOURCE_TOTAL_BYTES"
        echo "source_newest_epoch=$SOURCE_NEWEST_EPOCH"
        echo "temporary_archive_size=$archive_size"
        echo "packed_archive_size_observed=$archive_size"
        echo "elapsed_sec=$elapsed"
        echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S %z')"

    } > "${marker}.tmp"

    mv -f "${marker}.tmp" "$marker"
    chmod 600 "$marker"

    log INFO \
        "completion marker created: $marker"
}

create_preexisting_marker()
{
    local marker="$1"
    local archive_file="$2"

    {
        echo "status=CLOUD_PREEXISTING"
        echo "version=$VERSION"
        echo "archive=$archive_file"
        echo "cloud_verify=SUCCESS"
        echo "source_dir=$SOURCE_DIR"
        echo "source_files=unknown"
        echo "source_bytes=unknown"
        echo "source_newest_epoch=unknown"
        echo "temporary_archive_size=unknown"
        echo "elapsed_sec=0"
        echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S %z')"

    } > "${marker}.tmp"

    mv -f "${marker}.tmp" "$marker"
    chmod 600 "$marker"

    log INFO \
        "local marker created for pre-existing cloud object: $marker"
}

# ============================================================
# Temporary run directory cleanup
# ============================================================

cleanup_success_temp()
{
    local run_temp="$1"

    if ! yes_value "$CLEANUP_TEMP_AFTER_SUCCESS"; then

        log INFO \
            "successful temporary workspace retained by configuration: $run_temp"

        return 0
    fi

    if [[ -d "$run_temp" ]]; then

        rm -rf -- "$run_temp" || {
            log WARNING \
                "cannot remove successful temporary workspace: $run_temp"

            return 1
        }

        log INFO \
            "temporary workspace cleaned: $run_temp"
    fi

    return 0
}

cleanup_failed_temp()
{
    local run_temp="$1"

    [[ -d "$run_temp" ]] || return 0

    if yes_value "$PRESERVE_FAILED_TEMP"; then

        log WARNING \
            "failed temporary workspace preserved: $run_temp"

        return 0
    fi

    rm -rf -- "$run_temp" || true

    log INFO \
        "failed temporary workspace removed: $run_temp"

    return 0
}

# ============================================================
# Main upload
# ============================================================

upload_archive()
{
    local requested_name="${1:-}"

    local archive_name
    local archive_ext
    local archive_file
    local marker

    local run_id
    local run_temp
    local local_archive

    local start_epoch
    local now_epoch
    local elapsed

    local size=0
    local last_size=-1
    local max_archive_size=0

    local phase="PREPARE"
    local previous_phase=""

    local last_heartbeat_epoch=0

    local rc
    local archive_size=0
    local result_seen=0
    local target
    local -a target_args=()

    archive_name="$(normalize_archive_name "$requested_name")" || {
        log ERROR \
            "invalid archive name: ${requested_name:-<generated>}"

        return 2
    }

    archive_ext="$(archive_extension)"
    archive_file="${archive_name}${archive_ext}"

    marker="${STATE_DIR%/}/${archive_file}.done"

    # --------------------------------------------------------
    # Verify remote object before touching source/temp.
    # --------------------------------------------------------

    fetch_cloud_list || return 1

    if cloud_object_exists "$archive_file"; then

        log INFO \
            "cloud object already exists; duplicate upload prevented: archive=$archive_file"

        if [[ ! -f "$marker" ]]; then
            create_preexisting_marker "$marker" "$archive_file"
        fi

        return 0
    fi

    # --------------------------------------------------------
    # Source validation
    # --------------------------------------------------------

    validate_source_mount || return 1
    verify_source_stable || return 1
    build_upload_targets || return 1
    log_source_file_list || return 1
    log_upload_targets || return 1
    check_temp_space || return 1

    # --------------------------------------------------------
    # Per-run workspace
    # --------------------------------------------------------

    run_id="$(date '+%Y%m%d-%H%M%S')-$$"
    run_temp="${TEMP_WORKSPACE%/}/${archive_name}-${run_id}"

    mkdir -p "$run_temp" || {
        log ERROR \
            "cannot create run temporary workspace: $run_temp"

        return 1
    }

    chmod 700 "$run_temp" 2>/dev/null || true

    local_archive="${run_temp%/}/${archive_file}"

    CURRENT_RUN_TEMP_DIR="$run_temp"
    CURRENT_TOOL_LOG="${STATE_DIR}/.${archive_file}.${run_id}.tool.log"
    CURRENT_PHASE_FILE="${STATE_DIR}/.${archive_file}.${run_id}.phase"
    CURRENT_OUTPUT_DONE_FILE="${STATE_DIR}/.${archive_file}.${run_id}.output.done"
    CURRENT_PACKED_SIZE_FILE="${STATE_DIR}/.${archive_file}.${run_id}.packed-size"

    : > "$CURRENT_TOOL_LOG"
    : > "$CURRENT_PACKED_SIZE_FILE"
    printf 'PREPARE\n' > "$CURRENT_PHASE_FILE"
    rm -f "$CURRENT_OUTPUT_DONE_FILE"

    chmod 600 "$CURRENT_TOOL_LOG" "$CURRENT_PHASE_FILE" "$CURRENT_PACKED_SIZE_FILE"

    log INFO \
        "============================================================"

    log INFO \
        "upload starting"

    log INFO \
        "version=$VERSION"

    log INFO \
        "archive=$archive_file"

    log INFO \
        "source=$SOURCE_DIR"

    log INFO \
        "upload_target_mode=individual-files"

    log INFO \
        "upload_target_pattern=*.o3.signed"

    log INFO \
        "upload_target_count=$UPLOAD_TARGET_COUNT"

    log INFO \
        "source_files=$SOURCE_FILE_COUNT"

    log INFO \
        "source_bytes=$SOURCE_TOTAL_BYTES ($(format_bytes "$SOURCE_TOTAL_BYTES"))"

    log INFO \
        "ArchiveMechanism=$ARCHIVE_MECHANISM"

    log INFO \
        "EncryptionAlgorithm=$ENCRYPTION_ALGORITHM"

    log INFO \
        "TemporaryWorkspace=$run_temp"

    log INFO \
        "EncryptionKeyFile=$ENCRYPTION_KEY_FILE"

    log INFO \
        "============================================================"

    start_epoch="$(date +%s)"
    last_heartbeat_epoch="$start_epoch"

    # --------------------------------------------------------
    # Start uploader in separate process group.
    # --------------------------------------------------------

    # v1.3.9: pass each payload file as its own -TargetPath.
    # Vendor behavior verified in testing: individual file targets are stored
    # at the outer tar root by basename, so no top-level alldata/ directory
    # is embedded.
    for target in "${UPLOAD_TARGETS[@]}"; do
        target_args+=( -TargetPath "$target" )
    done

    (( ${#target_args[@]} > 0 )) || {
        log ERROR "internal error: upload target argument list is empty"
        cleanup_failed_temp "$run_temp"
        return 1
    }

    setsid \
        "$S3S_BIN" upload \
            -AccessKey "$ACCESS_KEY" \
            -SecretKey "$SECRET_KEY" \
            -ArchiveMechanism "$ARCHIVE_MECHANISM" \
            -ArchiveName "$archive_name" \
            -EncryptionAlgorithm "$ENCRYPTION_ALGORITHM" \
            -EncryptionKeyFilePath "$ENCRYPTION_KEY_FILE" \
            "${target_args[@]}" \
            -TemporaryWorksapce "${run_temp%/}/" \
        > >(process_upload_output) \
        2>&1 &

    UPLOAD_PID=$!

    log INFO \
        "upload process started PID=$UPLOAD_PID"

    # --------------------------------------------------------
    # Monitor.
    #
    # HiCloud CLI does not expose a reliable network byte
    # counter. We therefore report:
    #
    #   PREPARE/PACK : local archive growth
    #   UPLOAD       : heartbeat + local packed archive size
    #
    # We do NOT invent a cloud percentage.
    # --------------------------------------------------------

    while kill -0 "$UPLOAD_PID" 2>/dev/null; do

        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - start_epoch))

        if (( elapsed >= UPLOAD_TIMEOUT_SEC )); then

            log ERROR \
                "upload timeout after ${elapsed}s; terminating PID=$UPLOAD_PID"

            kill -TERM -- "-${UPLOAD_PID}" 2>/dev/null || true

            sleep 10

            if kill -0 "$UPLOAD_PID" 2>/dev/null; then

                log WARNING \
                    "upload did not terminate; sending SIGKILL"

                kill -KILL -- "-${UPLOAD_PID}" 2>/dev/null || true
            fi

            wait "$UPLOAD_PID" 2>/dev/null || true
            UPLOAD_PID=""

            cleanup_failed_temp "$run_temp"

            return 124
        fi

        size="$(get_file_size "$local_archive")"

        # Preserve the largest packed archive size observed. The
        # HiCloud CLI may remove the local .tar immediately after
        # a successful upload.
        if [[ "$size" =~ ^[0-9]+$ ]] &&
           (( size > max_archive_size )); then
            max_archive_size="$size"
        fi

        if [[ -r "$CURRENT_PHASE_FILE" ]]; then
            phase="$(head -n 1 "$CURRENT_PHASE_FILE" 2>/dev/null)"
        else
            phase="PREPARE"
        fi

        # A local archive may start growing before the CLI prints
        # its PACK completion line.
        if [[ "$phase" != "UPLOAD" &&
              "$phase" != "UPLOAD_SUCCESS" &&
              "$phase" != "RESULT_SUCCESS" &&
              "$size" =~ ^[0-9]+$ &&
              "$size" -gt 0 ]]; then

            phase="PACK"
        fi

        if [[ "$phase" != "$previous_phase" ]]; then

            log INFO \
                "phase changed: ${previous_phase:-START} -> $phase archive=$archive_file elapsed=${elapsed}s"

            previous_phase="$phase"
            last_heartbeat_epoch="$now_epoch"
        fi

        case "$phase" in

            PACK|PACKED|PATH_PARSE|PREPARE)

                if [[ "$size" =~ ^[0-9]+$ &&
                      "$size" -gt 0 &&
                      "$size" != "$last_size" ]]; then

                    log INFO \
                        "pack in-progress: archive=$archive_file local_size=$size ($(format_bytes "$size")) elapsed=${elapsed}s"

                    last_size="$size"
                    last_heartbeat_epoch="$now_epoch"
                fi
                ;;

            UPLOAD|UPLOAD_SUCCESS|RESULT_SUCCESS)

                if [[ "$size" =~ ^[0-9]+$ &&
                      "$size" != "$last_size" ]]; then

                    log INFO \
                        "packed archive ready: archive=$archive_file local_size=$size ($(format_bytes "$size"))"

                    last_size="$size"
                    last_heartbeat_epoch="$now_epoch"
                fi
                ;;
        esac

        if (( now_epoch - last_heartbeat_epoch >= MONITOR_HEARTBEAT_SEC )); then

            log INFO \
                "upload heartbeat: archive=$archive_file phase=$phase local_size=$size ($(format_bytes "$size")) elapsed=${elapsed}s"

            last_heartbeat_epoch="$now_epoch"
        fi

        sleep "$MONITOR_INTERVAL_SEC"
    done

    # --------------------------------------------------------
    # Collect process exit status.
    # --------------------------------------------------------

    wait "$UPLOAD_PID"
    rc=$?
    UPLOAD_PID=""

    # Wait briefly for process-substitution output handler to
    # consume final "(RESULT)" line.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -f "$CURRENT_OUTPUT_DONE_FILE" ]] && break
        sleep 1
    done

    # v1.3.10: import the size captured synchronously from the PACK line.
    # This closes the sampling gap for uploads that finish before the normal
    # monitor interval gets its first chance to stat the temporary archive.
    if [[ -s "$CURRENT_PACKED_SIZE_FILE" ]]; then
        size="$(head -n 1 "$CURRENT_PACKED_SIZE_FILE" 2>/dev/null || echo 0)"

        if [[ "$size" =~ ^[0-9]+$ ]] &&
           (( size > max_archive_size )); then
            max_archive_size="$size"
            log INFO \
                "packed archive size captured from PACK event: archive=$archive_file size=$max_archive_size ($(format_bytes "$max_archive_size"))"
        fi
    fi

    elapsed=$(( $(date +%s) - start_epoch ))
    archive_size="$(get_file_size "$local_archive")"

    # HiCloud CLI can delete the local packed archive after upload.
    # Fall back to the maximum size observed while PACK/UPLOAD ran.
    if [[ ! "$archive_size" =~ ^[0-9]+$ ]] ||
       (( archive_size <= 0 )); then

        if (( max_archive_size > 0 )); then
            log INFO \
                "local packed archive no longer present after upload; using maximum observed size=$max_archive_size ($(format_bytes "$max_archive_size"))"
            archive_size="$max_archive_size"
        else
            log WARNING \
                "packed archive size unavailable after upload"
            archive_size=0
        fi
    fi

    if (( rc != 0 )); then

        log ERROR \
            "upload command failed archive=$archive_file rc=$rc"

        cleanup_failed_temp "$run_temp"

        return "$rc"
    fi

    if grep -F -q -- "(RESULT) success" "$CURRENT_TOOL_LOG"; then
        result_seen=1
    fi

    if yes_value "$REQUIRE_RESULT_SUCCESS" &&
       (( result_seen == 0 )); then

        log ERROR \
            "upload process exited 0 but '(RESULT) success' was not observed"

        cleanup_failed_temp "$run_temp"

        return 1
    fi

    log INFO \
        "upload command completed successfully archive=$archive_file rc=$rc elapsed=${elapsed}s"

    # --------------------------------------------------------
    # Cloud-side existence verification.
    # --------------------------------------------------------

    if ! verify_cloud_object "$archive_file"; then

        cleanup_failed_temp "$run_temp"

        return 1
    fi

    # --------------------------------------------------------
    # Success marker.
    # --------------------------------------------------------

    create_done_marker \
        "$marker" \
        "$archive_file" \
        "$archive_size" \
        "$elapsed"

    log INFO \
        "============================================================"

    log INFO \
        "UPLOAD SUCCESS"

    log INFO \
        "archive=$archive_file"

    log INFO \
        "source_files=$SOURCE_FILE_COUNT"

    log INFO \
        "source_bytes=$SOURCE_TOTAL_BYTES ($(format_bytes "$SOURCE_TOTAL_BYTES"))"

    log INFO \
        "packed_archive_size_observed=$archive_size ($(format_bytes "$archive_size"))"

    log INFO \
        "elapsed=${elapsed} seconds"

    log INFO \
        "cloud_verify=SUCCESS"

    log INFO \
        "============================================================"

    cleanup_success_temp "$run_temp"

    rm -f \
        "$CURRENT_PHASE_FILE" \
        "$CURRENT_OUTPUT_DONE_FILE" \
        "$CURRENT_PACKED_SIZE_FILE" \
        "$CURRENT_TOOL_LOG" \
        2>/dev/null || true

    CURRENT_RUN_TEMP_DIR=""
    CURRENT_TOOL_LOG=""
    CURRENT_PHASE_FILE=""
    CURRENT_OUTPUT_DONE_FILE=""
    CURRENT_PACKED_SIZE_FILE=""

    return 0
}

# ============================================================
# Status
# ============================================================

show_status()
{
    local marker
    local archive
    local status
    local cloud_verify
    local source_files
    local source_bytes
    local archive_size
    local completed

    printf 'HiCloud Upload v%s\n\n' "$VERSION"
    printf 'Source directory:\n'
    printf '  %s\n\n' "$SOURCE_DIR"

    printf 'Completed uploads:\n\n'

    local found=0

    while IFS= read -r marker; do

        [[ -n "$marker" ]] || continue

        found=1

        archive="$(read_marker_value "$marker" archive)"
        status="$(read_marker_value "$marker" status)"
        cloud_verify="$(read_marker_value "$marker" cloud_verify)"
        source_files="$(read_marker_value "$marker" source_files)"
        source_bytes="$(read_marker_value "$marker" source_bytes)"
        archive_size="$(read_marker_value "$marker" temporary_archive_size)"
        completed="$(read_marker_value "$marker" completed_at)"

        printf '  %-28s status=%-18s cloud=%-7s files=%-8s source_bytes=%-14s archive_bytes=%-14s completed=%s\n' \
            "${archive:-unknown}" \
            "${status:-unknown}" \
            "${cloud_verify:-unknown}" \
            "${source_files:-unknown}" \
            "${source_bytes:-unknown}" \
            "${archive_size:-unknown}" \
            "${completed:-unknown}"

    done < <(
        find "$STATE_DIR" \
            -maxdepth 1 \
            -type f \
            -name '*.done' \
            -print 2>/dev/null |
        LC_ALL=C sort -r
    )

    if (( found == 0 )); then
        printf '  No completed upload found.\n'
    fi
}

# ============================================================
# Main
# ============================================================

ACTION="${1:-run}"

case "$ACTION" in

    run)

        acquire_lock || exit 0

        log INFO \
            "scheduled upload job started version=$VERSION"

        upload_archive "${2:-}"
        rc=$?

        if (( rc == 0 )); then
            log INFO \
                "scheduled upload job finished successfully"
        else
            log ERROR \
                "scheduled upload job failed rc=$rc"
        fi

        exit "$rc"
        ;;

    check-source)

        validate_source_mount || exit 1
        verify_source_stable || exit 1
        build_upload_targets || exit 1
        log_source_file_list || exit 1
        log_upload_targets || exit 1
        check_temp_space || exit 1

        printf '\nSource check SUCCESS\n'
        printf '  source      : %s\n' "$SOURCE_DIR"
        printf '  files       : %s\n' "$SOURCE_FILE_COUNT"
        printf '  bytes       : %s\n' "$SOURCE_TOTAL_BYTES"
        printf '  human       : %s\n' "$(format_bytes "$SOURCE_TOTAL_BYTES")"
        printf '  newest_epoch: %s\n' "$SOURCE_NEWEST_EPOCH"
        printf '  target_mode : individual-files\n'
        printf '  target_count: %s\n' "$UPLOAD_TARGET_COUNT"
        ;;

    list)

        fetch_cloud_list || exit 1

        printf '\nCloud files:\n\n'

        if [[ -n "$CLOUD_FILES" ]]; then
            printf '%s\n' "$CLOUD_FILES"
        else
            printf '  No files found.\n'
        fi
        ;;

    status)

        show_status
        ;;

    version|--version|-V)

        echo "hicloud_latest_upload_v1.3.10.sh v${VERSION}"
        ;;

    *)

        cat <<EOF
HiCloud Secure Storage Upload v${VERSION}

Usage:

  $0 run
  $0 run <ArchiveName>
  $0 check-source
  $0 list
  $0 status
  $0 version

Examples:

  # Default daily name: YYYYMMDD
  $0 run

  # Manual archive name
  $0 run testfile-20260917

  # Source/NFS/stability/disk precheck only
  $0 check-source

Important:

  - Do not include .tar in ArchiveName; if supplied it is normalized.
  - Existing cloud objects are never overwritten automatically.
  - Only regular *.o3.signed files are uploaded.
  - Each payload is passed as an individual -TargetPath.
  - Outer tar members are expected at tar root (no alldata/ prefix).
  - Duplicate basenames are rejected before upload.
  - Upload output line "EncryptionKey:" is redacted from script logs.
  - Failed per-run temporary workspace is preserved by default.

Configuration:

  $CONFIG_FILE

EOF
        exit 2
        ;;
esac
