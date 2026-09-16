#!/usr/bin/env bash
#
# HiCloud Secure Storage Latest Recovery
# Version: 1.3.3
#
# Adds selectable post-recovery restore verification:
#   POST_VERIFY_MODE=smallest|random|all
#   outer tar -> selected *.o3.signed -> GPG signature pinning
#   -> GPG decrypt layer 1 -> GPG decrypt layer 2 -> GPG decrypt layer 3
#   -> zstd integrity test -> inner tar listing test
#   -> safe inner extraction -> regular-file/readability verification
#   -> large-file progress/timeout + all-mode checkpoint/resume
#   -> adaptive sub-second polling + millisecond elapsed/throughput
#

set -uo pipefail

VERSION="1.3.3"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

CONFIG_FILE="${HICLOUD_RECOVERY_CONFIG:-/etc/hicloud-recovery.conf}"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

[[ -r "$CONFIG_FILE" ]] || die "cannot read config file: $CONFIG_FILE"
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${S3S_BIN:=/usr/local/bin/secure-storage-desktop-shell}"
: "${RECOVERY_DIR:=/data_bk/HiCloudSecretS3}"
: "${TEMP_WORKSPACE:=/data_bk/HiCloudSecretS3_tmp}"
: "${LOG_DIR:=/var/log/hicloud-recovery}"
: "${STATE_DIR:=/var/lib/hicloud-recovery}"
: "${LIST_RETRIES:=3}"
: "${LIST_RETRY_DELAY_SEC:=10}"
: "${RECOVERY_TIMEOUT_SEC:=43200}"
: "${MONITOR_INTERVAL_SEC:=30}"
: "${MONITOR_HEARTBEAT_SEC:=300}"
: "${STABLE_INTERVAL_SEC:=5}"
: "${STABLE_CHECK_COUNT:=3}"
: "${MIN_FREE_GB:=150}"
: "${VERIFY_TAR:=no}"
: "${CALCULATE_SHA256:=no}"

# Post-recovery verification defaults
: "${POST_VERIFY:=yes}"
: "${POST_VERIFY_MODE:=smallest}"
: "${POST_VERIFY_ALL_STOP_ON_FAILURE:=yes}"
: "${VERIFY_WORK_ROOT:=${TEMP_WORKSPACE%/}/postverify}"
: "${KEEP_VERIFY_WORK_ON_FAILURE:=no}"
: "${GPG_BIN:=/usr/bin/gpg}"
: "${GPG_HOMEDIR:=/root/.gnupg}"
: "${GPG_PASSPHRASE_FILE:=/root/.config/hicloud-recovery/gpg.passphrase}"
: "${GPG_EXPECTED_SIGNING_FPR:=}"
: "${GPG_EXPECTED_PRIMARY_FPR:=}"
: "${ZSTD_BIN:=/usr/bin/zstd}"
: "${POST_VERIFY_EXTRACT_INNER:=yes}"
: "${POST_VERIFY_REQUIRE_REGULAR_FILE:=yes}"
: "${POST_VERIFY_REQUIRE_NONEMPTY:=no}"
: "${KEEP_VERIFY_RESTORE_OUTPUT:=no}"

# v1.3.2 large-file progress / timeout / checkpoint defaults
: "${POST_VERIFY_PROGRESS_INTERVAL_SEC:=30}"
: "${POST_VERIFY_PROGRESS_POLL_SEC:=2}"   # legacy/fallback when adaptive polling is disabled
: "${POST_VERIFY_PROGRESS_HEARTBEAT_SEC:=300}"
: "${POST_VERIFY_MEMBER_TIMEOUT_SEC:=14400}"
: "${POST_VERIFY_GPG_LAYER_TIMEOUT_SEC:=7200}"
: "${POST_VERIFY_ZSTD_TIMEOUT_SEC:=7200}"
: "${POST_VERIFY_EXTRACT_TIMEOUT_SEC:=7200}"
: "${POST_VERIFY_CHECKPOINT:=yes}"
: "${POST_VERIFY_CHECKPOINT_DIR:=${STATE_DIR%/}/postverify-checkpoints}"

# v1.3.3 adaptive polling / millisecond timing defaults
: "${POST_VERIFY_ADAPTIVE_POLL:=yes}"
: "${POST_VERIFY_FAST_POLL_MS:=200}"
: "${POST_VERIFY_FAST_POLL_WINDOW_SEC:=10}"
: "${POST_VERIFY_SLOW_POLL_MS:=1000}"

bool_yes()
{
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_bool()
{
    case "${1,,}" in
        yes|true|1|on) printf 'yes\n' ;;
        no|false|0|off) printf 'no\n' ;;
        *) return 1 ;;
    esac
}

normalize_fpr()
{
    printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

for bool_var in POST_VERIFY POST_VERIFY_ALL_STOP_ON_FAILURE KEEP_VERIFY_WORK_ON_FAILURE POST_VERIFY_EXTRACT_INNER POST_VERIFY_REQUIRE_REGULAR_FILE POST_VERIFY_REQUIRE_NONEMPTY KEEP_VERIFY_RESTORE_OUTPUT POST_VERIFY_CHECKPOINT POST_VERIFY_ADAPTIVE_POLL VERIFY_TAR CALCULATE_SHA256; do
    bool_value="${!bool_var}"
    bool_normalized="$(normalize_bool "$bool_value")" || die "invalid boolean setting: ${bool_var}=${bool_value}"
    printf -v "$bool_var" '%s' "$bool_normalized"
done

[[ -n "${ACCESS_KEY:-}" ]] || die "ACCESS_KEY is not configured"
[[ -n "${SECRET_KEY:-}" ]] || die "SECRET_KEY is not configured"
[[ "$ACCESS_KEY" != "CHANGE_ME" ]] || die "ACCESS_KEY is still CHANGE_ME"
[[ "$SECRET_KEY" != "CHANGE_ME" ]] || die "SECRET_KEY is still CHANGE_ME"
[[ -x "$S3S_BIN" ]] || die "command not executable: $S3S_BIN"
[[ -n "${ENCRYPTION_KEY_FILE:-}" ]] || die "ENCRYPTION_KEY_FILE is not configured"
[[ -r "$ENCRYPTION_KEY_FILE" ]] || die "encryption key not readable: $ENCRYPTION_KEY_FILE"

for cmd in flock setsid stat df awk sed sort head tee find date mv mktemp tr wc tar dd timeout sha256sum cp grep; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

if bool_yes "$POST_VERIFY"; then
    POST_VERIFY_MODE="${POST_VERIFY_MODE,,}"
    case "$POST_VERIFY_MODE" in
        smallest|random|all) ;;
        *) die "invalid POST_VERIFY_MODE=$POST_VERIFY_MODE (expected: smallest|random|all)" ;;
    esac

    [[ -x "$GPG_BIN" ]] || die "GPG_BIN not executable: $GPG_BIN"
    [[ -d "$GPG_HOMEDIR" ]] || die "GPG_HOMEDIR does not exist: $GPG_HOMEDIR"
    [[ -x "$ZSTD_BIN" ]] || die "ZSTD_BIN not executable: $ZSTD_BIN"
    [[ -r "$GPG_PASSPHRASE_FILE" ]] || die "GPG passphrase file not readable: $GPG_PASSPHRASE_FILE"

    for numeric_var in POST_VERIFY_PROGRESS_INTERVAL_SEC POST_VERIFY_PROGRESS_POLL_SEC POST_VERIFY_PROGRESS_HEARTBEAT_SEC POST_VERIFY_MEMBER_TIMEOUT_SEC POST_VERIFY_GPG_LAYER_TIMEOUT_SEC POST_VERIFY_ZSTD_TIMEOUT_SEC POST_VERIFY_EXTRACT_TIMEOUT_SEC POST_VERIFY_FAST_POLL_MS POST_VERIFY_FAST_POLL_WINDOW_SEC POST_VERIFY_SLOW_POLL_MS; do
        numeric_value="${!numeric_var}"
        [[ "$numeric_value" =~ ^[0-9]+$ ]] && (( numeric_value > 0 )) || die "invalid positive integer setting: ${numeric_var}=${numeric_value}"
    done
    [[ -n "$GPG_EXPECTED_SIGNING_FPR" ]] || die "GPG_EXPECTED_SIGNING_FPR is required when POST_VERIFY=yes"

    if [[ "$POST_VERIFY_MODE" == "random" ]]; then
        command -v shuf >/dev/null 2>&1 || die "required command not found for POST_VERIFY_MODE=random: shuf"
    fi

    pass_mode="$(stat -c '%a' "$GPG_PASSPHRASE_FILE" 2>/dev/null || echo 777)"
    pass_owner="$(stat -c '%u' "$GPG_PASSPHRASE_FILE" 2>/dev/null || echo -1)"
    [[ "$pass_mode" =~ ^[0-7]{3,4}$ ]] || die "cannot determine permissions for $GPG_PASSPHRASE_FILE"
    pass_mode_num=$((8#$pass_mode))
    (( (pass_mode_num & 077) == 0 )) || die "GPG passphrase file must not be group/world accessible: $GPG_PASSPHRASE_FILE mode=$pass_mode"
    (( pass_owner == EUID )) || die "GPG passphrase file owner uid=$pass_owner does not match current uid=$EUID"
fi

mkdir -p "$RECOVERY_DIR" "$TEMP_WORKSPACE" "$LOG_DIR" "$STATE_DIR"
chmod 700 "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

if bool_yes "$POST_VERIFY"; then
    mkdir -p "$VERIFY_WORK_ROOT"
    chmod 700 "$VERIFY_WORK_ROOT" 2>/dev/null || true

    if bool_yes "$POST_VERIFY_CHECKPOINT"; then
        mkdir -p "$POST_VERIFY_CHECKPOINT_DIR"
        chmod 700 "$POST_VERIFY_CHECKPOINT_DIR" 2>/dev/null || true
    fi
fi

RUN_DATE="$(date '+%Y%m%d')"
RUN_LOG="${LOG_DIR}/hicloud-recovery-${RUN_DATE}.log"
touch "$RUN_LOG"
chmod 600 "$RUN_LOG"

log()
{
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$RUN_LOG"
}

LIST_OUTPUT=""
FILES=""
LATEST_FILE=""
RECOVERY_PID=""
VERIFY_CHILD_PID=""

# Post-verify globals written to the completion marker
POST_VERIFY_RESULT=""
POST_VERIFY_MODE_USED=""
POST_VERIFY_TOTAL=0
POST_VERIFY_VERIFIED=0
POST_VERIFY_FAILED=0
POST_VERIFY_MEMBER=""
POST_VERIFY_MEMBER_SIZE=""
POST_VERIFY_SIGNING_FPR=""
POST_VERIFY_PRIMARY_FPR=""
POST_VERIFY_PAYLOAD_SIZE=0
POST_VERIFY_INNER_ENTRIES=0
POST_VERIFY_EXTRACT_RESULT=""
POST_VERIFY_REGULAR_FILES=0
POST_VERIFY_READABLE_FILES=0
POST_VERIFY_NONEMPTY_FILES=0
POST_VERIFY_AT=""

LOCK_FILE="/run/lock/hicloud-latest-recovery.lock"

acquire_lock()
{
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log INFO "another recovery process is already running; exit"
        return 1
    fi
    return 0
}

cleanup_signal()
{
    local signal_name="${1:-UNKNOWN}"
    log WARNING "received termination signal: $signal_name"

    if [[ -n "${RECOVERY_PID:-}" ]] && kill -0 "$RECOVERY_PID" 2>/dev/null; then
        log WARNING "terminating recovery process group PID=$RECOVERY_PID"
        kill -TERM -- "-${RECOVERY_PID}" 2>/dev/null || true
        sleep 5
        if kill -0 "$RECOVERY_PID" 2>/dev/null; then
            log WARNING "recovery process still running; sending SIGKILL"
            kill -KILL -- "-${RECOVERY_PID}" 2>/dev/null || true
        fi
    fi

    if [[ -n "${VERIFY_CHILD_PID:-}" ]] && kill -0 "$VERIFY_CHILD_PID" 2>/dev/null; then
        log WARNING "terminating post-verify process group PID=$VERIFY_CHILD_PID"
        kill -TERM -- "-${VERIFY_CHILD_PID}" 2>/dev/null || true
        sleep 2
        if kill -0 "$VERIFY_CHILD_PID" 2>/dev/null; then
            kill -KILL -- "-${VERIFY_CHILD_PID}" 2>/dev/null || true
        fi
    fi
    exit 130
}

trap 'cleanup_signal INT' INT
trap 'cleanup_signal TERM' TERM
trap 'cleanup_signal HUP' HUP

get_file_size()
{
    local file="$1"
    if [[ -f "$file" ]]; then
        stat -c '%s' "$file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

check_free_space()
{
    local dir="$1"
    local free_kb free_gb min_kb

    [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || {
        log ERROR "invalid MIN_FREE_GB=$MIN_FREE_GB"
        return 1
    }

    (( MIN_FREE_GB == 0 )) && return 0

    free_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 {print $4}')"
    [[ "$free_kb" =~ ^[0-9]+$ ]] || {
        log ERROR "cannot determine free space: $dir"
        return 1
    }

    min_kb=$(( MIN_FREE_GB * 1024 * 1024 ))
    free_gb=$(( free_kb / 1024 / 1024 ))

    if (( free_kb < min_kb )); then
        log ERROR "insufficient free space: dir=$dir free=${free_gb}GB required=${MIN_FREE_GB}GB"
        return 1
    fi

    log INFO "disk-space OK: dir=$dir free=${free_gb}GB required=${MIN_FREE_GB}GB"
    return 0
}

fetch_cloud_list()
{
    local attempt rc output
    LIST_OUTPUT=""

    for ((attempt=1; attempt<=LIST_RETRIES; attempt++)); do
        log INFO "requesting cloud file list attempt=${attempt}/${LIST_RETRIES}"
        output="$(
            "$S3S_BIN" list \
                -AccessKey "$ACCESS_KEY" \
                -SecretKey "$SECRET_KEY" \
                2>&1
        )"
        rc=$?
        printf '%s\n' "$output" >> "$RUN_LOG"

        if (( rc == 0 )); then
            LIST_OUTPUT="$output"
            log INFO "cloud list command completed successfully"
            return 0
        fi

        log WARNING "cloud list failed rc=$rc attempt=$attempt"
        (( attempt < LIST_RETRIES )) && sleep "$LIST_RETRY_DELAY_SEC"
    done

    log ERROR "cloud list failed after ${LIST_RETRIES} attempts"
    return 1
}

parse_cloud_files()
{
    FILES="$(
        printf '%s\n' "$LIST_OUTPUT" |
        sed -nE 's/.*file:[[:space:]]*([0-9]{8}\.tar)([[:space:]].*)?$/\1/p' |
        LC_ALL=C sort -u
    )"

    [[ -n "$FILES" ]] || {
        log ERROR "no YYYYMMDD.tar files found in cloud list"
        return 1
    }
    return 0
}

select_latest_file()
{
    LATEST_FILE="$(printf '%s\n' "$FILES" | LC_ALL=C sort -r | head -n 1)"
    [[ "$LATEST_FILE" =~ ^[0-9]{8}\.tar$ ]] || {
        log ERROR "cannot determine latest archive"
        return 1
    }
    log INFO "latest cloud archive: $LATEST_FILE"
    return 0
}

read_marker_value()
{
    local marker="$1" key="$2"
    awk -v key="$key" '
        index($0, key "=") == 1 {
            sub("^[^=]*=", "")
            print
            exit
        }
    ' "$marker" 2>/dev/null
}

recovery_marker_base_valid()
{
    local marker="$1" target="$2" archive="$3"
    local marker_status marker_archive marker_size current_size

    [[ -f "$marker" ]] || return 1
    [[ -s "$target" ]] || return 1

    marker_status="$(read_marker_value "$marker" status)"
    marker_archive="$(read_marker_value "$marker" archive)"
    marker_size="$(read_marker_value "$marker" size_bytes)"
    current_size="$(get_file_size "$target")"

    [[ "$marker_status" == "SUCCESS" ]] || return 1
    [[ "$marker_archive" == "$archive" ]] || return 1
    [[ "$marker_size" =~ ^[0-9]+$ ]] || return 1
    [[ "$current_size" =~ ^[0-9]+$ ]] || return 1
    (( current_size > 0 )) || return 1
    (( marker_size == current_size )) || return 1
    return 0
}

post_verify_marker_valid()
{
    local marker="$1"
    local result mode total verified failed member member_size signing primary payload_bytes entries
    local extract_state regular_files readable_files nonempty_files marker_require_regular marker_require_nonempty marker_extract_enabled
    local expected_signing expected_primary expected_mode expected_extract

    bool_yes "$POST_VERIFY" || return 0

    result="$(read_marker_value "$marker" post_verify)"
    mode="$(read_marker_value "$marker" post_verify_mode)"
    total="$(read_marker_value "$marker" post_verify_total)"
    verified="$(read_marker_value "$marker" post_verify_verified)"
    failed="$(read_marker_value "$marker" post_verify_failed)"
    member="$(read_marker_value "$marker" post_verify_member)"
    member_size="$(read_marker_value "$marker" post_verify_member_size)"
    signing="$(normalize_fpr "$(read_marker_value "$marker" post_verify_signing_fpr)")"
    primary="$(normalize_fpr "$(read_marker_value "$marker" post_verify_primary_fpr)")"
    payload_bytes="$(read_marker_value "$marker" post_verify_payload_bytes_total)"
    entries="$(read_marker_value "$marker" post_verify_inner_entries_total)"

    extract_state="$(read_marker_value "$marker" post_verify_extract)"
    regular_files="$(read_marker_value "$marker" post_verify_regular_files_total)"
    readable_files="$(read_marker_value "$marker" post_verify_readable_files_total)"
    nonempty_files="$(read_marker_value "$marker" post_verify_nonempty_files_total)"
    marker_extract_enabled="$(read_marker_value "$marker" post_verify_extract_enabled)"
    marker_require_regular="$(read_marker_value "$marker" post_verify_require_regular_file)"
    marker_require_nonempty="$(read_marker_value "$marker" post_verify_require_nonempty)"

    expected_signing="$(normalize_fpr "$GPG_EXPECTED_SIGNING_FPR")"
    expected_primary="$(normalize_fpr "$GPG_EXPECTED_PRIMARY_FPR")"
    expected_mode="${POST_VERIFY_MODE,,}"

    [[ "$result" == "SUCCESS" ]] || return 1
    [[ "$mode" == "$expected_mode" ]] || return 1
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    [[ "$verified" =~ ^[0-9]+$ ]] || return 1
    [[ "$failed" =~ ^[0-9]+$ ]] || return 1
    [[ "$payload_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$entries" =~ ^[0-9]+$ ]] || return 1
    (( total > 0 )) || return 1
    (( verified == total )) || return 1
    (( failed == 0 )) || return 1
    (( payload_bytes > 0 )) || return 1
    (( entries > 0 )) || return 1
    [[ "$signing" == "$expected_signing" ]] || return 1

    if [[ -n "$expected_primary" ]]; then
        [[ "$primary" == "$expected_primary" ]] || return 1
    fi

    case "$mode" in
        smallest|random)
            (( total == 1 )) || return 1
            [[ "$member" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.o3\.signed$ ]] || return 1
            [[ "$member_size" =~ ^[0-9]+$ ]] || return 1
            (( member_size > 0 )) || return 1
            ;;
        all)
            ;;
        *)
            return 1
            ;;
    esac

    if bool_yes "$POST_VERIFY_EXTRACT_INNER"; then
        expected_extract="yes"
        [[ "${marker_extract_enabled,,}" == "$expected_extract" ]] || return 1
        [[ "$extract_state" == "SUCCESS" ]] || return 1
        [[ "$regular_files" =~ ^[0-9]+$ ]] || return 1
        [[ "$readable_files" =~ ^[0-9]+$ ]] || return 1
        [[ "$nonempty_files" =~ ^[0-9]+$ ]] || return 1
        (( readable_files == regular_files )) || return 1

        [[ "${marker_require_regular,,}" == "${POST_VERIFY_REQUIRE_REGULAR_FILE,,}" ]] || return 1
        [[ "${marker_require_nonempty,,}" == "${POST_VERIFY_REQUIRE_NONEMPTY,,}" ]] || return 1

        if bool_yes "$POST_VERIFY_REQUIRE_REGULAR_FILE"; then
            (( regular_files > 0 )) || return 1
        fi

        if bool_yes "$POST_VERIFY_REQUIRE_NONEMPTY"; then
            (( nonempty_files == regular_files )) || return 1
        fi
    else
        [[ "${marker_extract_enabled,,}" == "no" ]] || return 1
        [[ "$extract_state" == "DISABLED" ]] || return 1
    fi

    return 0
}

full_marker_valid()
{
    local marker="$1" target="$2" archive="$3"
    recovery_marker_base_valid "$marker" "$target" "$archive" || return 1
    post_verify_marker_valid "$marker" || return 1
    return 0
}

preserve_previous_recovery()
{
    local target_path="$1" decrypt_path="$2" marker="$3"
    local timestamp destination

    timestamp="$(date '+%Y%m%d-%H%M%S')"

    if [[ -f "$marker" ]]; then
        destination="${marker}.stale.${timestamp}"
        log WARNING "invalid/stale completion marker found; moving to $destination"
        mv -- "$marker" "$destination" || return 1
    fi

    if [[ -f "$target_path" ]]; then
        destination="${target_path}.partial.${timestamp}"
        log WARNING "existing target without valid completion marker found; moving to $destination"
        mv -- "$target_path" "$destination" || return 1
    fi

    if [[ -f "$decrypt_path" ]]; then
        destination="${decrypt_path}.partial.${timestamp}"
        log WARNING "existing decrypt file from previous recovery found; moving to $destination"
        mv -- "$decrypt_path" "$destination" || return 1
    fi

    return 0
}

verify_file_stable()
{
    local file="$1"
    local previous_size=-1 current_size=0 stable_count=0

    log INFO "checking recovered file size stability"

    while (( stable_count < STABLE_CHECK_COUNT )); do
        [[ -f "$file" ]] || {
            log ERROR "recovered file does not exist: $file"
            return 1
        }

        current_size="$(get_file_size "$file")"
        [[ "$current_size" =~ ^[0-9]+$ ]] && (( current_size > 0 )) || {
            log ERROR "invalid recovered file size: $current_size"
            return 1
        }

        if (( current_size == previous_size )); then
            stable_count=$((stable_count + 1))
            log INFO "stable check ${stable_count}/${STABLE_CHECK_COUNT}: size=${current_size} bytes"
        else
            stable_count=0
            log INFO "file size changed: previous=${previous_size} current=${current_size}"
            previous_size="$current_size"
        fi

        (( stable_count < STABLE_CHECK_COUNT )) && sleep "$STABLE_INTERVAL_SEC"
    done

    log INFO "recovered file size is stable: ${current_size} bytes"
    return 0
}

verify_tar()
{
    local file="$1"
    case "${VERIFY_TAR,,}" in
        yes|true|1)
            log INFO "starting outer tar integrity/list verification: $file"
            if tar -tf "$file" >/dev/null 2>>"$RUN_LOG"; then
                log INFO "outer tar verification successful"
                return 0
            fi
            log ERROR "outer tar verification failed: $file"
            return 1
            ;;
        *)
            log INFO "outer tar verification disabled"
            return 0
            ;;
    esac
}

SAMPLE_MEMBER=""
SAMPLE_MEMBER_SIZE=""

list_safe_signed_members()
{
    local archive="$1"

    # Observed GNU tar listing:
    # mode owner/group size YYYY-MM-DD HH:MM filename
    # Only simple basename regular files ending in .o3.signed are accepted.
    LC_ALL=C tar -tvf "$archive" 2>>"$RUN_LOG" |
        awk '$1 ~ /^-/ && $3 ~ /^[0-9]+$/ && NF >= 6 {print $3 "\t" $6}' |
        awk -F '\t' '$1 ~ /^[0-9]+$/ && $1 > 0 && $2 ~ /^[A-Za-z0-9][A-Za-z0-9._-]*\.o3\.signed$/ {print}' |
        LC_ALL=C sort -n -k1,1 -k2,2
}

select_verify_members()
{
    local archive="$1" output_file="$2" manifest_file="$3"
    local candidate_count

    : > "$manifest_file"
    : > "$output_file"

    if ! list_safe_signed_members "$archive" > "$manifest_file"; then
        log ERROR "failed to enumerate safe *.o3.signed members in archive=$archive"
        return 1
    fi

    candidate_count="$(wc -l < "$manifest_file" | awk '{print $1}')"
    [[ "$candidate_count" =~ ^[0-9]+$ ]] || candidate_count=0

    if (( candidate_count <= 0 )); then
        log ERROR "no safe *.o3.signed regular member found in archive=$archive"
        return 1
    fi

    case "$POST_VERIFY_MODE" in
        smallest)
            head -n 1 "$manifest_file" > "$output_file"
            ;;
        random)
            shuf -n 1 "$manifest_file" > "$output_file"
            ;;
        all)
            cat "$manifest_file" > "$output_file"
            ;;
        *)
            log ERROR "unsupported POST_VERIFY_MODE=$POST_VERIFY_MODE"
            return 1
            ;;
    esac

    POST_VERIFY_TOTAL="$(wc -l < "$output_file" | awk '{print $1}')"
    [[ "$POST_VERIFY_TOTAL" =~ ^[0-9]+$ ]] || POST_VERIFY_TOTAL=0
    (( POST_VERIFY_TOTAL > 0 )) || {
        log ERROR "post-verify selection is empty mode=$POST_VERIFY_MODE"
        return 1
    }

    log INFO "post-verify selection complete: mode=$POST_VERIFY_MODE candidates=$candidate_count selected=$POST_VERIFY_TOTAL"
    return 0
}

# ============================================================
# v1.3.3 progress / timeout helpers
#
# Key design:
#   * process polling is independent from progress logging
#   * short stages are polled at sub-second resolution
#   * long stages automatically fall back to a lower polling rate
#   * progress logs still default to every 30 seconds
#   * checkpoint/resume logic is unchanged from v1.3.2
# ============================================================

now_ms()
{
    date +%s%3N
}

format_elapsed_ms()
{
    local ms="$1"
    awk -v ms="$ms" 'BEGIN { printf "%.3fs", ms/1000.0 }'
}

format_progress_pct()
{
    local current="$1" total="$2"
    awk -v c="$current" -v t="$total" 'BEGIN {
        if (t <= 0) { printf "n/a"; exit }
        p=(c*100.0)/t; if (p > 100) p=100; if (p < 0) p=0;
        printf "%.1f%%", p
    }'
}

format_mib_per_sec()
{
    local bytes="$1" seconds="$2"
    awk -v b="$bytes" -v s="$seconds" 'BEGIN {
        if (s <= 0) { printf "n/a"; exit }
        printf "%.2f", (b/1048576.0)/s
    }'
}

format_mib_per_sec_ms()
{
    local bytes="$1" elapsed_ms="$2"
    awk -v b="$bytes" -v ms="$elapsed_ms" 'BEGIN {
        if (ms <= 0) { printf "n/a"; exit }
        printf "%.2f", (b/1048576.0)/(ms/1000.0)
    }'
}

sleep_ms()
{
    local ms="$1" seconds
    seconds="$(awk -v ms="$ms" 'BEGIN { printf "%.3f", ms/1000.0 }')"
    sleep "$seconds"
}

adaptive_poll_sleep()
{
    local elapsed_ms="$1"
    local poll_ms

    if bool_yes "$POST_VERIFY_ADAPTIVE_POLL"; then
        if (( elapsed_ms < POST_VERIFY_FAST_POLL_WINDOW_SEC * 1000 )); then
            poll_ms="$POST_VERIFY_FAST_POLL_MS"
        else
            poll_ms="$POST_VERIFY_SLOW_POLL_MS"
        fi
    else
        poll_ms=$((POST_VERIFY_PROGRESS_POLL_SEC * 1000))
    fi

    sleep_ms "$poll_ms"
}

kill_process_group()
{
    local pid="$1" label="$2"
    kill -TERM -- "-${pid}" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log WARNING "${label}: process still running after TERM; sending KILL pid=$pid"
        kill -KILL -- "-${pid}" 2>/dev/null || true
    fi
}

member_step_timeout()
{
    local member_start="$1" step_limit="$2"
    local now elapsed remaining

    now="$(date +%s)"
    elapsed=$((now - member_start))
    remaining=$((POST_VERIFY_MEMBER_TIMEOUT_SEC - elapsed))

    if (( remaining <= 0 )); then
        echo 0
        return 1
    fi

    if (( step_limit < remaining )); then
        echo "$step_limit"
    else
        echo "$remaining"
    fi
    return 0
}

monitor_output_process()
{
    local pid="$1" output="$2" expected_bytes="$3" label="$4" timeout_sec="$5" start_ms="$6"
    local now_ms_value elapsed_ms size=0 last_size=-1 last_log_ms="$start_ms" rc timed_out=0 pct throughput elapsed_text

    VERIFY_CHILD_PID="$pid"

    while kill -0 "$pid" 2>/dev/null; do
        now_ms_value="$(now_ms)"
        elapsed_ms=$((now_ms_value - start_ms))
        size="$(get_file_size "$output")"

        if (( elapsed_ms >= timeout_sec * 1000 )); then
            elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
            log ERROR "${label} TIMEOUT elapsed=${elapsed_text} timeout=${timeout_sec}s output_size=${size}"
            timed_out=1
            kill_process_group "$pid" "$label"
            break
        fi

        if (( now_ms_value - last_log_ms >= POST_VERIFY_PROGRESS_INTERVAL_SEC * 1000 )); then
            pct="$(format_progress_pct "$size" "$expected_bytes")"
            throughput="$(format_mib_per_sec_ms "$size" "$elapsed_ms")"
            elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
            log INFO "${label} in-progress output_size=${size} bytes expected=${expected_bytes} progress=${pct} elapsed=${elapsed_text} avg=${throughput}MiB/s"
            last_log_ms="$now_ms_value"
            last_size="$size"
        elif (( size != last_size && now_ms_value - last_log_ms >= POST_VERIFY_PROGRESS_HEARTBEAT_SEC * 1000 )); then
            pct="$(format_progress_pct "$size" "$expected_bytes")"
            elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
            log INFO "${label} heartbeat output_size=${size} bytes expected=${expected_bytes} progress=${pct} elapsed=${elapsed_text}"
            last_log_ms="$now_ms_value"
            last_size="$size"
        fi

        adaptive_poll_sleep "$elapsed_ms"
    done

    wait "$pid" 2>/dev/null
    rc=$?
    VERIFY_CHILD_PID=""

    (( timed_out == 0 )) || return 124
    return "$rc"
}

monitor_heartbeat_process()
{
    local pid="$1" label="$2" timeout_sec="$3" start_ms="$4"
    local now_ms_value elapsed_ms last_log_ms="$start_ms" rc timed_out=0 elapsed_text

    VERIFY_CHILD_PID="$pid"

    while kill -0 "$pid" 2>/dev/null; do
        now_ms_value="$(now_ms)"
        elapsed_ms=$((now_ms_value - start_ms))

        if (( elapsed_ms >= timeout_sec * 1000 )); then
            elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
            log ERROR "${label} TIMEOUT elapsed=${elapsed_text} timeout=${timeout_sec}s"
            timed_out=1
            kill_process_group "$pid" "$label"
            break
        fi

        if (( now_ms_value - last_log_ms >= POST_VERIFY_PROGRESS_INTERVAL_SEC * 1000 )); then
            elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
            log INFO "${label} in-progress elapsed=${elapsed_text}"
            last_log_ms="$now_ms_value"
        fi

        adaptive_poll_sleep "$elapsed_ms"
    done

    wait "$pid" 2>/dev/null
    rc=$?
    VERIFY_CHILD_PID=""

    (( timed_out == 0 )) || return 124
    return "$rc"
}

monitor_restore_process()
{
    local pid="$1" restore_dir="$2" label="$3" timeout_sec="$4" start_ms="$5"
    local now_ms_value elapsed_ms last_log_ms="$start_ms" rc timed_out=0 files bytes elapsed_text

    VERIFY_CHILD_PID="$pid"

    while kill -0 "$pid" 2>/dev/null; do
        now_ms_value="$(now_ms)"
        elapsed_ms=$((now_ms_value - start_ms))

        if (( elapsed_ms >= timeout_sec * 1000 )); then
            elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
            log ERROR "${label} TIMEOUT elapsed=${elapsed_text} timeout=${timeout_sec}s"
            timed_out=1
            kill_process_group "$pid" "$label"
            break
        fi

        if (( now_ms_value - last_log_ms >= POST_VERIFY_PROGRESS_INTERVAL_SEC * 1000 )); then
            files="$(find "$restore_dir" -type f -printf '.' 2>/dev/null | wc -c | awk '{print $1}')"
            bytes="$(find "$restore_dir" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s+0}')"
            elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
            log INFO "${label} in-progress restored_files=${files:-0} restored_bytes=${bytes:-0} elapsed=${elapsed_text}"
            last_log_ms="$now_ms_value"
        fi

        adaptive_poll_sleep "$elapsed_ms"
    done

    wait "$pid" 2>/dev/null
    rc=$?
    VERIFY_CHILD_PID=""

    (( timed_out == 0 )) || return 124
    return "$rc"
}

# ============================================================
# v1.3.2 all-mode checkpoint / resume
# ============================================================

checkpoint_path_for_archive()
{
    local archive="$1"
    printf '%s/%s.postverify-all.checkpoint\n' "${POST_VERIFY_CHECKPOINT_DIR%/}" "${archive##*/}"
}

checkpoint_completed_count()
{
    local checkpoint="$1"
    [[ -f "$checkpoint" ]] || { echo 0; return; }
    awk -F '\t' '$1 == "done" {c++} END {print c+0}' "$checkpoint"
}

checkpoint_member_done()
{
    local checkpoint="$1" size="$2" member="$3"
    [[ -f "$checkpoint" ]] || return 1
    awk -F '\t' -v s="$size" -v m="$member" '$1 == "done" && $2 == s && $3 == m {found=1} END {exit found ? 0 : 1}' "$checkpoint"
}

checkpoint_valid()
{
    local checkpoint="$1" archive="$2" archive_size="$3" manifest_hash="$4"
    local cp_version cp_path cp_size cp_mode cp_hash cp_sign cp_primary cp_extract cp_regular cp_nonempty cp_total

    [[ -f "$checkpoint" ]] || return 1

    cp_version="$(read_marker_value "$checkpoint" checkpoint_version)"
    cp_path="$(read_marker_value "$checkpoint" archive_path)"
    cp_size="$(read_marker_value "$checkpoint" archive_size)"
    cp_mode="$(read_marker_value "$checkpoint" post_verify_mode)"
    cp_hash="$(read_marker_value "$checkpoint" manifest_sha256)"
    cp_sign="$(normalize_fpr "$(read_marker_value "$checkpoint" expected_signing_fpr)")"
    cp_primary="$(normalize_fpr "$(read_marker_value "$checkpoint" expected_primary_fpr)")"
    cp_extract="$(read_marker_value "$checkpoint" extract_inner)"
    cp_regular="$(read_marker_value "$checkpoint" require_regular_file)"
    cp_nonempty="$(read_marker_value "$checkpoint" require_nonempty)"
    cp_total="$(read_marker_value "$checkpoint" total)"

    [[ "$cp_version" == "1" ]] || return 1
    [[ "$cp_path" == "$archive" ]] || return 1
    [[ "$cp_size" == "$archive_size" ]] || return 1
    [[ "$cp_mode" == "all" ]] || return 1
    [[ "$cp_hash" == "$manifest_hash" ]] || return 1
    [[ "$cp_sign" == "$(normalize_fpr "$GPG_EXPECTED_SIGNING_FPR")" ]] || return 1
    [[ "$cp_primary" == "$(normalize_fpr "$GPG_EXPECTED_PRIMARY_FPR")" ]] || return 1
    [[ "$cp_extract" == "$POST_VERIFY_EXTRACT_INNER" ]] || return 1
    [[ "$cp_regular" == "$POST_VERIFY_REQUIRE_REGULAR_FILE" ]] || return 1
    [[ "$cp_nonempty" == "$POST_VERIFY_REQUIRE_NONEMPTY" ]] || return 1
    [[ "$cp_total" == "$POST_VERIFY_TOTAL" ]] || return 1
    return 0
}

checkpoint_initialize()
{
    local checkpoint="$1" archive="$2" archive_size="$3" manifest_hash="$4" total="$5"
    local tmp="${checkpoint}.tmp.$$"

    {
        echo "checkpoint_version=1"
        echo "script_version=$VERSION"
        echo "archive_path=$archive"
        echo "archive_size=$archive_size"
        echo "post_verify_mode=all"
        echo "manifest_sha256=$manifest_hash"
        echo "expected_signing_fpr=$(normalize_fpr "$GPG_EXPECTED_SIGNING_FPR")"
        echo "expected_primary_fpr=$(normalize_fpr "$GPG_EXPECTED_PRIMARY_FPR")"
        echo "extract_inner=$POST_VERIFY_EXTRACT_INNER"
        echo "require_regular_file=$POST_VERIFY_REQUIRE_REGULAR_FILE"
        echo "require_nonempty=$POST_VERIFY_REQUIRE_NONEMPTY"
        echo "total=$total"
        echo "created_at=$(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "updated_at=$(date '+%Y-%m-%d %H:%M:%S %z')"
    } > "$tmp" || return 1

    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$checkpoint"
    log INFO "all-mode checkpoint initialized: $checkpoint total=$total"
}

checkpoint_append_success()
{
    local checkpoint="$1" size="$2" member="$3" payload="$4" entries="$5" regular="$6" readable="$7" nonempty="$8" signing="$9" primary="${10}"
    local tmp="${checkpoint}.tmp.$$"

    checkpoint_member_done "$checkpoint" "$size" "$member" && return 0

    awk '!/^updated_at=/' "$checkpoint" > "$tmp" || return 1
    printf 'updated_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$tmp"
    printf 'done\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$size" "$member" "$payload" "$entries" "$regular" "$readable" "$nonempty" "$signing" "$primary" >> "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$checkpoint"
}

checkpoint_load_totals()
{
    local checkpoint="$1"
    local tag size member payload entries regular readable nonempty signing primary

    POST_VERIFY_VERIFIED=0
    POST_VERIFY_PAYLOAD_SIZE=0
    POST_VERIFY_INNER_ENTRIES=0
    POST_VERIFY_REGULAR_FILES=0
    POST_VERIFY_READABLE_FILES=0
    POST_VERIFY_NONEMPTY_FILES=0

    while IFS=$'\t' read -r tag size member payload entries regular readable nonempty signing primary; do
        [[ "$tag" == "done" ]] || continue
        POST_VERIFY_VERIFIED=$((POST_VERIFY_VERIFIED + 1))
        POST_VERIFY_PAYLOAD_SIZE=$((POST_VERIFY_PAYLOAD_SIZE + payload))
        POST_VERIFY_INNER_ENTRIES=$((POST_VERIFY_INNER_ENTRIES + entries))
        POST_VERIFY_REGULAR_FILES=$((POST_VERIFY_REGULAR_FILES + regular))
        POST_VERIFY_READABLE_FILES=$((POST_VERIFY_READABLE_FILES + readable))
        POST_VERIFY_NONEMPTY_FILES=$((POST_VERIFY_NONEMPTY_FILES + nonempty))
        POST_VERIFY_SIGNING_FPR="$signing"
        POST_VERIFY_PRIMARY_FPR="$primary"
    done < "$checkpoint"
}

prepare_all_checkpoint()
{
    local archive="$1" selected_file="$2"
    local archive_size manifest_hash checkpoint stale count

    ALL_CHECKPOINT_FILE=""
    bool_yes "$POST_VERIFY_CHECKPOINT" || return 0
    [[ "$POST_VERIFY_MODE" == "all" ]] || return 0

    archive_size="$(get_file_size "$archive")"
    manifest_hash="$(sha256sum "$selected_file" | awk '{print $1}')"
    checkpoint="$(checkpoint_path_for_archive "$archive")"

    if [[ -f "$checkpoint" ]]; then
        if checkpoint_valid "$checkpoint" "$archive" "$archive_size" "$manifest_hash"; then
            ALL_CHECKPOINT_FILE="$checkpoint"
            checkpoint_load_totals "$checkpoint"
            count="$(checkpoint_completed_count "$checkpoint")"
            log INFO "all-mode checkpoint resume available: completed=$count/$POST_VERIFY_TOTAL file=$checkpoint"
            return 0
        fi

        stale="${checkpoint}.stale.$(date '+%Y%m%d-%H%M%S')"
        log WARNING "stale/incompatible all-mode checkpoint found; moving to $stale"
        mv -- "$checkpoint" "$stale" || return 1
    fi

    checkpoint_initialize "$checkpoint" "$archive" "$archive_size" "$manifest_hash" "$POST_VERIFY_TOTAL" || return 1
    ALL_CHECKPOINT_FILE="$checkpoint"
    return 0
}

cleanup_all_checkpoint()
{
    local archive="$1" checkpoint
    bool_yes "$POST_VERIFY_CHECKPOINT" || return 0
    checkpoint="$(checkpoint_path_for_archive "$archive")"
    if [[ -f "$checkpoint" ]]; then
        rm -f -- "$checkpoint" && log INFO "all-mode checkpoint cleared after durable completion marker: $checkpoint"
    fi
}

ALL_CHECKPOINT_FILE=""

VERIFIED_SIGNING_FPR=""
VERIFIED_PRIMARY_FPR=""

verify_gpg_signature()
{
    local signed_file="$1" member_start="$2" label="$3"
    local status_file status_output rc signing primary expected_signing expected_primary
    local input_size step_timeout start_ms elapsed_ms elapsed_text

    status_file="${signed_file}.verify.status"
    input_size="$(get_file_size "$signed_file")"
    step_timeout="$(member_step_timeout "$member_start" "$POST_VERIFY_GPG_LAYER_TIMEOUT_SEC")" || {
        log ERROR "GPG signature verification cannot start: member timeout already exhausted label=$label"
        return 124
    }

    log INFO "GPG signature verification started label=$label input_size=${input_size} bytes timeout=${step_timeout}s"
    start_ms="$(now_ms)"

    setsid "$GPG_BIN" \
        --homedir "$GPG_HOMEDIR" \
        --batch \
        --no-tty \
        --status-fd 1 \
        --verify "$signed_file" \
        > "$status_file" \
        2>>"$RUN_LOG" &
    local pid=$!

    if monitor_heartbeat_process "$pid" "GPG signature verification label=$label input_size=${input_size}" "$step_timeout" "$start_ms"; then
        rc=0
    else
        rc=$?
    fi

    if (( rc != 0 )); then
        log ERROR "GPG signature verification failed rc=$rc file=$signed_file"
        rm -f -- "$status_file"
        return "$rc"
    fi

    status_output="$(cat "$status_file" 2>/dev/null)"
    rm -f -- "$status_file"

    signing="$(printf '%s\n' "$status_output" | awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {print $3; exit}')"
    primary="$(printf '%s\n' "$status_output" | awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {print $NF; exit}')"

    signing="$(normalize_fpr "$signing")"
    primary="$(normalize_fpr "$primary")"
    expected_signing="$(normalize_fpr "$GPG_EXPECTED_SIGNING_FPR")"
    expected_primary="$(normalize_fpr "$GPG_EXPECTED_PRIMARY_FPR")"

    [[ -n "$signing" ]] || {
        log ERROR "GPG VALIDSIG status not found"
        return 1
    }

    if [[ "$signing" != "$expected_signing" ]]; then
        log ERROR "GPG signing fingerprint mismatch actual=$signing expected=$expected_signing"
        return 1
    fi

    if [[ -n "$expected_primary" && "$primary" != "$expected_primary" ]]; then
        log ERROR "GPG primary fingerprint mismatch actual=$primary expected=$expected_primary"
        return 1
    fi

    VERIFIED_SIGNING_FPR="$signing"
    VERIFIED_PRIMARY_FPR="$primary"
    elapsed_ms=$(( $(now_ms) - start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    log INFO "GPG signature VALID and fingerprint pinned: signing_fpr=$signing primary_fpr=${primary:-unknown} elapsed=${elapsed_text}"
    return 0
}

gpg_decrypt_layer()
{
    local input="$1" output="$2" label="$3" member_start="$4"
    local input_size step_timeout start_ms rc final_size elapsed_ms elapsed_text throughput

    input_size="$(get_file_size "$input")"
    step_timeout="$(member_step_timeout "$member_start" "$POST_VERIFY_GPG_LAYER_TIMEOUT_SEC")" || {
        log ERROR "GPG decrypt ${label} cannot start: member timeout already exhausted"
        return 124
    }

    log INFO "GPG decrypt ${label} started input_size=${input_size} bytes timeout=${step_timeout}s"
    start_ms="$(now_ms)"

    setsid "$GPG_BIN" \
        --homedir "$GPG_HOMEDIR" \
        --batch \
        --yes \
        --no-tty \
        --pinentry-mode loopback \
        --passphrase-file "$GPG_PASSPHRASE_FILE" \
        --decrypt "$input" \
        > "$output" \
        2>>"$RUN_LOG" &

    local pid=$!
    if monitor_output_process "$pid" "$output" "$input_size" "GPG decrypt ${label}" "$step_timeout" "$start_ms"; then
        rc=0
    else
        rc=$?
    fi

    if (( rc != 0 )); then
        log ERROR "GPG decrypt ${label} failed rc=$rc"
        return "$rc"
    fi

    [[ -s "$output" ]] || {
        log ERROR "GPG decrypt ${label} produced empty output"
        return 1
    }

    final_size="$(get_file_size "$output")"
    elapsed_ms=$(( $(now_ms) - start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    throughput="$(format_mib_per_sec_ms "$final_size" "$elapsed_ms")"
    log INFO "GPG decrypt ${label} successful size=${final_size} bytes elapsed=${elapsed_text} avg=${throughput}MiB/s"
    return 0
}

safe_inner_tar_manifest()
{
    local payload_zst="$1" names_file="$2" verbose_file="$3" member_start="$4" member="$5"
    local name step_timeout start_ms rc elapsed_ms elapsed_text

    [[ -s "$names_file" ]] || {
        log ERROR "inner tar names manifest missing/empty for safety inspection member=$member"
        return 1
    }

    step_timeout="$(member_step_timeout "$member_start" "$POST_VERIFY_ZSTD_TIMEOUT_SEC")" || {
        log ERROR "inner tar verbose safety listing cannot start: member timeout already exhausted member=$member"
        return 124
    }

    start_ms="$(now_ms)"
    setsid bash -c '
        zstd_bin="$1"; payload="$2"; verbose="$3"; run_log="$4"
        "$zstd_bin" -dc "$payload" 2>>"$run_log" | tar -tvf - >"$verbose" 2>>"$run_log"
    ' _ "$ZSTD_BIN" "$payload_zst" "$verbose_file" "$RUN_LOG" &
    local pid=$!

    if monitor_heartbeat_process "$pid" "inner tar safety listing member=$member" "$step_timeout" "$start_ms"; then
        rc=0
    else
        rc=$?
    fi
    (( rc == 0 )) || {
        log ERROR "cannot read verbose inner tar listing for safety inspection member=$member rc=$rc"
        return "$rc"
    }

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue

        case "$name" in
            /*)
                log ERROR "unsafe absolute path in inner tar: $name"
                return 1
                ;;
        esac

        if printf '%s\n' "$name" | awk -F/ '{ for (i=1; i<=NF; i++) if ($i == "..") exit 1; exit 0 }'; then
            :
        else
            log ERROR "unsafe parent traversal in inner tar: $name"
            return 1
        fi
    done < "$names_file"

    if awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" { exit 1 }' "$verbose_file"; then
        :
    else
        log ERROR "unsafe special entry type found in inner tar; only regular files/directories are allowed"
        return 1
    fi

    elapsed_ms=$(( $(now_ms) - start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    log INFO "inner tar path/type safety check successful member=$member elapsed=${elapsed_text}"
    return 0
}

keep_restore_output()
{
    local restore_dir="$1" archive="$2" member="$3"
    local keep_root keep_dir timestamp

    bool_yes "$KEEP_VERIFY_RESTORE_OUTPUT" || return 0

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    keep_root="${VERIFY_WORK_ROOT%/}/kept/${archive##*/}"
    keep_dir="${keep_root}/${member}.restore.${timestamp}"

    mkdir -p "$keep_root" || return 1
    chmod 700 "${VERIFY_WORK_ROOT%/}/kept" "$keep_root" 2>/dev/null || true

    if ! mv -- "$restore_dir" "$keep_dir"; then
        log ERROR "cannot preserve verification restore output: $restore_dir -> $keep_dir"
        return 1
    fi

    chmod -R u+rwX,go-rwx "$keep_dir" 2>/dev/null || true
    log INFO "verification restore output retained: $keep_dir"
    return 0
}

verify_inner_extract()
{
    local payload_zst="$1" restore_dir="$2" archive="$3" member="$4"
    local names_file="$5" verbose_file="$6" member_start="$7"
    local regular_files=0 readable_files=0 nonempty_files=0 f
    local step_timeout start_ms rc elapsed_ms elapsed_text

    ONE_REGULAR_FILES=0
    ONE_READABLE_FILES=0
    ONE_NONEMPTY_FILES=0

    safe_inner_tar_manifest "$payload_zst" "$names_file" "$verbose_file" "$member_start" "$member"
    rc=$?
    (( rc == 0 )) || return "$rc"

    mkdir -p "$restore_dir" || {
        log ERROR "cannot create inner restore directory: $restore_dir"
        return 1
    }
    chmod 700 "$restore_dir" 2>/dev/null || true

    step_timeout="$(member_step_timeout "$member_start" "$POST_VERIFY_EXTRACT_TIMEOUT_SEC")" || {
        log ERROR "inner restore extraction cannot start: member timeout already exhausted member=$member"
        return 124
    }

    log INFO "inner restore extraction started member=$member timeout=${step_timeout}s"
    start_ms="$(now_ms)"

    setsid bash -c '
        zstd_bin="$1"; payload="$2"; restore_dir="$3"; run_log="$4"
        "$zstd_bin" -dc "$payload" 2>>"$run_log" | \
            tar -xf - -C "$restore_dir" --no-same-owner --no-same-permissions 2>>"$run_log"
    ' _ "$ZSTD_BIN" "$payload_zst" "$restore_dir" "$RUN_LOG" &
    local pid=$!

    if monitor_restore_process "$pid" "$restore_dir" "inner restore extraction member=$member" "$step_timeout" "$start_ms"; then
        rc=0
    else
        rc=$?
    fi

    if (( rc != 0 )); then
        log ERROR "inner restore extraction failed member=$member rc=$rc"
        return "$rc"
    fi

    while IFS= read -r -d '' f; do
        if (( $(date +%s) - member_start >= POST_VERIFY_MEMBER_TIMEOUT_SEC )); then
            log ERROR "inner restore readability verification TIMEOUT member=$member timeout=${POST_VERIFY_MEMBER_TIMEOUT_SEC}s"
            return 124
        fi

        regular_files=$((regular_files + 1))

        if [[ -r "$f" ]]; then
            if dd if="$f" of=/dev/null bs=64K count=1 status=none 2>>"$RUN_LOG"; then
                readable_files=$((readable_files + 1))
            else
                log ERROR "restored regular file cannot be read: $f"
                return 1
            fi
        else
            log ERROR "restored regular file is not readable: $f"
            return 1
        fi

        [[ -s "$f" ]] && nonempty_files=$((nonempty_files + 1))
    done < <(find "$restore_dir" -type f -print0)

    if bool_yes "$POST_VERIFY_REQUIRE_REGULAR_FILE" && (( regular_files <= 0 )); then
        log ERROR "inner restore contains no regular files member=$member"
        return 1
    fi

    if (( readable_files != regular_files )); then
        log ERROR "inner restore readability mismatch member=$member readable=$readable_files regular=$regular_files"
        return 1
    fi

    if bool_yes "$POST_VERIFY_REQUIRE_NONEMPTY" && (( nonempty_files != regular_files )); then
        log ERROR "inner restore contains empty regular file(s) member=$member nonempty=$nonempty_files regular=$regular_files"
        return 1
    fi

    ONE_REGULAR_FILES="$regular_files"
    ONE_READABLE_FILES="$readable_files"
    ONE_NONEMPTY_FILES="$nonempty_files"

    elapsed_ms=$(( $(now_ms) - start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    log INFO "inner restore extraction successful member=$member regular_files=$regular_files readable_files=$readable_files nonempty_files=$nonempty_files elapsed=${elapsed_text}"

    keep_restore_output "$restore_dir" "$archive" "$member" || return 1
    return 0
}

ONE_PAYLOAD_SIZE=0
ONE_INNER_ENTRIES=0
ONE_REGULAR_FILES=0
ONE_READABLE_FILES=0
ONE_NONEMPTY_FILES=0

verify_one_signed_member()
{
    local archive="$1" member_size="$2" member="$3" verify_root="$4" ordinal="$5" total="$6"
    local workdir signed_file layer1 layer2 payload_zst inner_list inner_verbose restore_dir
    local actual_size payload_size inner_entries member_start member_start_ms step_timeout start_ms rc elapsed_ms elapsed_text throughput

    ONE_PAYLOAD_SIZE=0
    ONE_INNER_ENTRIES=0
    ONE_REGULAR_FILES=0
    ONE_READABLE_FILES=0
    ONE_NONEMPTY_FILES=0

    member_start="$(date +%s)"
    member_start_ms="$(now_ms)"
    workdir="$(mktemp -d "${verify_root%/}/member.${ordinal}.XXXXXX")" || {
        log ERROR "cannot create member verification work directory"
        return 1
    }
    chmod 700 "$workdir" 2>/dev/null || true

    signed_file="${workdir}/${member}"
    layer1="${workdir}/layer1.pgp"
    layer2="${workdir}/layer2.pgp"
    payload_zst="${workdir}/payload.tar.zst"
    inner_list="${workdir}/inner_tar.list"
    inner_verbose="${workdir}/inner_tar.verbose"
    restore_dir="${workdir}/restore"

    log INFO "post-verify member started: ${ordinal}/${total} member=$member size=$member_size bytes member_timeout=${POST_VERIFY_MEMBER_TIMEOUT_SEC}s"

    step_timeout="$(member_step_timeout "$member_start" "$POST_VERIFY_EXTRACT_TIMEOUT_SEC")" || {
        log ERROR "outer member extraction cannot start: member timeout already exhausted member=$member"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return 124
    }

    start_ms="$(now_ms)"
    setsid tar \
        --extract \
        --file="$archive" \
        --directory="$workdir" \
        --no-same-owner \
        --no-same-permissions \
        -- "$member" \
        2>>"$RUN_LOG" &
    local pid=$!

    if monitor_output_process "$pid" "$signed_file" "$member_size" "outer member extract ${ordinal}/${total} member=$member" "$step_timeout" "$start_ms"; then
        rc=0
    else
        rc=$?
    fi

    if (( rc != 0 )); then
        log ERROR "failed to extract selected member=$member rc=$rc"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return "$rc"
    fi

    actual_size="$(get_file_size "$signed_file")"
    if [[ ! -s "$signed_file" || "$actual_size" != "$member_size" ]]; then
        log ERROR "selected member size mismatch member=$member listed=$member_size extracted=$actual_size"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return 1
    fi

    elapsed_ms=$(( $(now_ms) - start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    throughput="$(format_mib_per_sec_ms "$actual_size" "$elapsed_ms")"
    log INFO "outer member extract ${ordinal}/${total} member=$member successful size=${actual_size} bytes elapsed=${elapsed_text} avg=${throughput}MiB/s"

    if ! verify_gpg_signature "$signed_file" "$member_start" "${ordinal}/${total} member=$member" ||
       ! gpg_decrypt_layer "$signed_file" "$layer1" "layer1-signed-payload ${ordinal}/${total} member=$member" "$member_start" ||
       ! gpg_decrypt_layer "$layer1" "$layer2" "layer2-rsa ${ordinal}/${total} member=$member" "$member_start" ||
       ! gpg_decrypt_layer "$layer2" "$payload_zst" "layer3-symmetric ${ordinal}/${total} member=$member" "$member_start"; then

        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return 1
    fi

    step_timeout="$(member_step_timeout "$member_start" "$POST_VERIFY_ZSTD_TIMEOUT_SEC")" || {
        log ERROR "zstd integrity test cannot start: member timeout already exhausted member=$member"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return 124
    }

    log INFO "zstd integrity test started member=$member timeout=${step_timeout}s"
    start_ms="$(now_ms)"
    setsid "$ZSTD_BIN" -t "$payload_zst" >>"$RUN_LOG" 2>&1 &
    pid=$!
    if monitor_heartbeat_process "$pid" "zstd integrity test member=$member" "$step_timeout" "$start_ms"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        log ERROR "zstd integrity test failed member=$member rc=$rc"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return "$rc"
    fi

    payload_size="$(get_file_size "$payload_zst")"
    elapsed_ms=$(( $(now_ms) - start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    log INFO "zstd integrity test successful member=$member payload_size=$payload_size bytes elapsed=${elapsed_text}"

    step_timeout="$(member_step_timeout "$member_start" "$POST_VERIFY_ZSTD_TIMEOUT_SEC")" || {
        log ERROR "inner tar listing cannot start: member timeout already exhausted member=$member"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return 124
    }

    log INFO "inner tar stream verification started member=$member timeout=${step_timeout}s"
    start_ms="$(now_ms)"
    setsid bash -c '
        zstd_bin="$1"; payload="$2"; inner_list="$3"; run_log="$4"
        "$zstd_bin" -dc "$payload" 2>>"$run_log" | tar -tf - >"$inner_list" 2>>"$run_log"
    ' _ "$ZSTD_BIN" "$payload_zst" "$inner_list" "$RUN_LOG" &
    pid=$!

    if monitor_heartbeat_process "$pid" "inner tar stream verification member=$member" "$step_timeout" "$start_ms"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        log ERROR "inner tar stream verification failed member=$member rc=$rc"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return "$rc"
    fi

    inner_entries="$(wc -l < "$inner_list" | awk '{print $1}')"
    [[ "$inner_entries" =~ ^[0-9]+$ ]] || inner_entries=0

    if (( inner_entries <= 0 )); then
        log ERROR "inner tar is readable but contains no entries member=$member"
        bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
        return 1
    fi

    elapsed_ms=$(( $(now_ms) - start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    log INFO "inner tar verification successful member=$member entries=$inner_entries elapsed=${elapsed_text}"
    log INFO "inner tar first entries follow member=$member"
    head -n 20 "$inner_list" | sed 's/^/    /' >> "$RUN_LOG"

    if bool_yes "$POST_VERIFY_EXTRACT_INNER"; then
        verify_inner_extract "$payload_zst" "$restore_dir" "$archive" "$member" "$inner_list" "$inner_verbose" "$member_start"
        rc=$?
        if (( rc != 0 )); then
            log ERROR "inner restore extraction/readability verification failed member=$member rc=$rc"
            bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE" || rm -rf -- "$workdir"
            return "$rc"
        fi
    fi

    ONE_PAYLOAD_SIZE="$payload_size"
    ONE_INNER_ENTRIES="$inner_entries"

    rm -rf -- "$workdir"
    elapsed_ms=$(( $(now_ms) - member_start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"
    log INFO "post-verify member SUCCESS: ${ordinal}/${total} member=$member elapsed=${elapsed_text}"
    return 0
}

post_verify_archive()
{
    local archive="$1"
    local verify_root manifest_file selected_file
    local member_size member ordinal=0 rc=0 verify_start_ms elapsed_ms elapsed_text

    POST_VERIFY_RESULT=""
    POST_VERIFY_MODE_USED=""
    POST_VERIFY_TOTAL=0
    POST_VERIFY_VERIFIED=0
    POST_VERIFY_FAILED=0
    POST_VERIFY_MEMBER=""
    POST_VERIFY_MEMBER_SIZE=""
    POST_VERIFY_SIGNING_FPR=""
    POST_VERIFY_PRIMARY_FPR=""
    POST_VERIFY_PAYLOAD_SIZE=0
    POST_VERIFY_INNER_ENTRIES=0
    POST_VERIFY_EXTRACT_RESULT=""
    POST_VERIFY_REGULAR_FILES=0
    POST_VERIFY_READABLE_FILES=0
    POST_VERIFY_NONEMPTY_FILES=0
    POST_VERIFY_AT=""
    ALL_CHECKPOINT_FILE=""

    bool_yes "$POST_VERIFY" || {
        POST_VERIFY_RESULT="DISABLED"
        POST_VERIFY_MODE_USED="disabled"
        return 0
    }

    verify_start_ms="$(now_ms)"
    verify_root="$(mktemp -d "${VERIFY_WORK_ROOT%/}/verify.${archive##*/}.XXXXXX")" || {
        log ERROR "cannot create post-verify root directory"
        return 1
    }
    chmod 700 "$verify_root" 2>/dev/null || true

    manifest_file="${verify_root}/signed-members.manifest"
    selected_file="${verify_root}/selected-members.manifest"

    log INFO "post-recovery verification started archive=$archive mode=$POST_VERIFY_MODE"
    log INFO "post-verify controls: progress_interval=${POST_VERIFY_PROGRESS_INTERVAL_SEC}s adaptive_poll=$POST_VERIFY_ADAPTIVE_POLL fast_poll=${POST_VERIFY_FAST_POLL_MS}ms fast_window=${POST_VERIFY_FAST_POLL_WINDOW_SEC}s slow_poll=${POST_VERIFY_SLOW_POLL_MS}ms member_timeout=${POST_VERIFY_MEMBER_TIMEOUT_SEC}s gpg_timeout=${POST_VERIFY_GPG_LAYER_TIMEOUT_SEC}s zstd_timeout=${POST_VERIFY_ZSTD_TIMEOUT_SEC}s extract_timeout=${POST_VERIFY_EXTRACT_TIMEOUT_SEC}s checkpoint=$POST_VERIFY_CHECKPOINT"

    if ! tar -tf "$archive" >/dev/null 2>>"$RUN_LOG"; then
        log ERROR "outer tar cannot be listed: $archive"
        rc=1
    elif ! select_verify_members "$archive" "$selected_file" "$manifest_file"; then
        rc=1
    else
        POST_VERIFY_MODE_USED="$POST_VERIFY_MODE"

        if [[ "$POST_VERIFY_MODE" == "all" ]] && bool_yes "$POST_VERIFY_CHECKPOINT"; then
            if ! prepare_all_checkpoint "$archive" "$selected_file"; then
                log ERROR "cannot prepare all-mode checkpoint"
                rc=1
            fi
        fi

        if (( rc == 0 )); then
            while IFS=$'\t' read -r member_size member; do
                [[ -n "$member" ]] || continue
                ordinal=$((ordinal + 1))

                if [[ "$POST_VERIFY_MODE" != "all" ]]; then
                    POST_VERIFY_MEMBER="$member"
                    POST_VERIFY_MEMBER_SIZE="$member_size"
                    log INFO "post-verify selected member: mode=$POST_VERIFY_MODE member=$member size=$member_size bytes"
                elif [[ -n "$ALL_CHECKPOINT_FILE" ]] && checkpoint_member_done "$ALL_CHECKPOINT_FILE" "$member_size" "$member"; then
                    log INFO "all-mode checkpoint resume skip: ${ordinal}/${POST_VERIFY_TOTAL} member=$member size=$member_size bytes"
                    continue
                fi

                if verify_one_signed_member "$archive" "$member_size" "$member" "$verify_root" "$ordinal" "$POST_VERIFY_TOTAL"; then
                    POST_VERIFY_VERIFIED=$((POST_VERIFY_VERIFIED + 1))
                    POST_VERIFY_PAYLOAD_SIZE=$((POST_VERIFY_PAYLOAD_SIZE + ONE_PAYLOAD_SIZE))
                    POST_VERIFY_INNER_ENTRIES=$((POST_VERIFY_INNER_ENTRIES + ONE_INNER_ENTRIES))
                    POST_VERIFY_REGULAR_FILES=$((POST_VERIFY_REGULAR_FILES + ONE_REGULAR_FILES))
                    POST_VERIFY_READABLE_FILES=$((POST_VERIFY_READABLE_FILES + ONE_READABLE_FILES))
                    POST_VERIFY_NONEMPTY_FILES=$((POST_VERIFY_NONEMPTY_FILES + ONE_NONEMPTY_FILES))
                    POST_VERIFY_SIGNING_FPR="$VERIFIED_SIGNING_FPR"
                    POST_VERIFY_PRIMARY_FPR="$VERIFIED_PRIMARY_FPR"

                    if [[ "$POST_VERIFY_MODE" == "all" && -n "$ALL_CHECKPOINT_FILE" ]]; then
                        if ! checkpoint_append_success "$ALL_CHECKPOINT_FILE" "$member_size" "$member" \
                            "$ONE_PAYLOAD_SIZE" "$ONE_INNER_ENTRIES" "$ONE_REGULAR_FILES" "$ONE_READABLE_FILES" "$ONE_NONEMPTY_FILES" \
                            "$VERIFIED_SIGNING_FPR" "$VERIFIED_PRIMARY_FPR"; then
                            log ERROR "cannot persist all-mode checkpoint after member=$member"
                            POST_VERIFY_FAILED=$((POST_VERIFY_FAILED + 1))
                            rc=1
                            break
                        fi
                        log INFO "all-mode checkpoint saved: completed=$POST_VERIFY_VERIFIED/$POST_VERIFY_TOTAL member=$member"
                    fi
                else
                    POST_VERIFY_FAILED=$((POST_VERIFY_FAILED + 1))
                    rc=1
                    log ERROR "post-verify member FAILED: ${ordinal}/${POST_VERIFY_TOTAL} member=$member"

                    if [[ "$POST_VERIFY_MODE" != "all" ]] || bool_yes "$POST_VERIFY_ALL_STOP_ON_FAILURE"; then
                        break
                    fi
                fi
            done < "$selected_file"
        fi

        if (( POST_VERIFY_VERIFIED == POST_VERIFY_TOTAL && POST_VERIFY_FAILED == 0 )); then
            POST_VERIFY_RESULT="SUCCESS"
            if bool_yes "$POST_VERIFY_EXTRACT_INNER"; then
                POST_VERIFY_EXTRACT_RESULT="SUCCESS"
            else
                POST_VERIFY_EXTRACT_RESULT="DISABLED"
            fi
            POST_VERIFY_AT="$(date '+%Y-%m-%d %H:%M:%S %z')"
            rc=0
        else
            POST_VERIFY_RESULT="FAILED"
            if bool_yes "$POST_VERIFY_EXTRACT_INNER"; then
                POST_VERIFY_EXTRACT_RESULT="FAILED"
            else
                POST_VERIFY_EXTRACT_RESULT="DISABLED"
            fi
            rc=1
        fi
    fi

    elapsed_ms=$(( $(now_ms) - verify_start_ms ))
    elapsed_text="$(format_elapsed_ms "$elapsed_ms")"

    if (( rc == 0 )); then
        log INFO "post-recovery verification SUCCESS mode=$POST_VERIFY_MODE verified=$POST_VERIFY_VERIFIED/$POST_VERIFY_TOTAL payload_bytes_total=$POST_VERIFY_PAYLOAD_SIZE inner_entries_total=$POST_VERIFY_INNER_ENTRIES extract=${POST_VERIFY_EXTRACT_RESULT:-DISABLED} regular_files=$POST_VERIFY_REGULAR_FILES readable_files=$POST_VERIFY_READABLE_FILES elapsed=${elapsed_text}"
        rm -rf -- "$verify_root"
    else
        log ERROR "post-recovery verification FAILED mode=$POST_VERIFY_MODE verified=$POST_VERIFY_VERIFIED total=$POST_VERIFY_TOTAL failed=$POST_VERIFY_FAILED elapsed=${elapsed_text}"
        if [[ "$POST_VERIFY_MODE" == "all" && -n "$ALL_CHECKPOINT_FILE" ]]; then
            log WARNING "all-mode checkpoint retained for resume: completed=$(checkpoint_completed_count "$ALL_CHECKPOINT_FILE")/$POST_VERIFY_TOTAL file=$ALL_CHECKPOINT_FILE"
        fi
        if bool_yes "$KEEP_VERIFY_WORK_ON_FAILURE"; then
            log WARNING "keeping post-verify root directory for investigation: $verify_root"
        else
            rm -rf -- "$verify_root"
        fi
    fi

    return "$rc"
}

create_done_marker()
{
    local target="$1" archive="$2" marker="$3"
    local size sha256="disabled"

    size="$(get_file_size "$target")"

    if bool_yes "$CALCULATE_SHA256"; then
        log INFO "calculating SHA256"
        sha256="$(sha256sum "$target" | awk '{print $1}')"
    fi

    {
        echo "status=SUCCESS"
        echo "version=$VERSION"
        echo "archive=$archive"
        echo "path=$target"
        echo "size_bytes=$size"
        echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "sha256=$sha256"

        if bool_yes "$POST_VERIFY"; then
            echo "post_verify=${POST_VERIFY_RESULT:-UNKNOWN}"
            echo "post_verify_mode=${POST_VERIFY_MODE_USED:-$POST_VERIFY_MODE}"
            echo "post_verify_total=${POST_VERIFY_TOTAL:-0}"
            echo "post_verify_verified=${POST_VERIFY_VERIFIED:-0}"
            echo "post_verify_failed=${POST_VERIFY_FAILED:-0}"
            echo "post_verify_member=${POST_VERIFY_MEMBER:-}"
            echo "post_verify_member_size=${POST_VERIFY_MEMBER_SIZE:-0}"
            echo "post_verify_signing_fpr=${POST_VERIFY_SIGNING_FPR:-}"
            echo "post_verify_primary_fpr=${POST_VERIFY_PRIMARY_FPR:-}"
            echo "post_verify_payload_bytes_total=${POST_VERIFY_PAYLOAD_SIZE:-0}"
            echo "post_verify_inner_entries_total=${POST_VERIFY_INNER_ENTRIES:-0}"
            echo "post_verify_extract=${POST_VERIFY_EXTRACT_RESULT:-UNKNOWN}"
            if bool_yes "$POST_VERIFY_EXTRACT_INNER"; then
                echo "post_verify_extract_enabled=yes"
            else
                echo "post_verify_extract_enabled=no"
            fi
            echo "post_verify_require_regular_file=${POST_VERIFY_REQUIRE_REGULAR_FILE,,}"
            echo "post_verify_require_nonempty=${POST_VERIFY_REQUIRE_NONEMPTY,,}"
            echo "post_verify_regular_files_total=${POST_VERIFY_REGULAR_FILES:-0}"
            echo "post_verify_readable_files_total=${POST_VERIFY_READABLE_FILES:-0}"
            echo "post_verify_nonempty_files_total=${POST_VERIFY_NONEMPTY_FILES:-0}"
            echo "post_verify_verified_at=${POST_VERIFY_AT:-}"
        else
            echo "post_verify=DISABLED"
            echo "post_verify_mode=disabled"
            echo "post_verify_total=0"
            echo "post_verify_verified=0"
            echo "post_verify_failed=0"
            echo "post_verify_extract=DISABLED"
            echo "post_verify_extract_enabled=no"
            echo "post_verify_require_regular_file=no"
            echo "post_verify_require_nonempty=no"
            echo "post_verify_regular_files_total=0"
            echo "post_verify_readable_files_total=0"
            echo "post_verify_nonempty_files_total=0"
        fi
    } > "${marker}.tmp"

    mv -f "${marker}.tmp" "$marker"
    chmod 600 "$marker"
    log INFO "completion marker created: $marker"

    if bool_yes "$POST_VERIFY" && [[ "${POST_VERIFY_MODE_USED:-}" == "all" ]] && [[ "${POST_VERIFY_RESULT:-}" == "SUCCESS" ]]; then
        cleanup_all_checkpoint "$target"
    fi
}

recover_latest()
{
    local archive="$1"
    local target_path decrypt_path marker
    local start_epoch now_epoch elapsed
    local size=0 decrypt_size=0
    local last_size=-1 last_decrypt_size=-1
    local rc phase="WAITING" new_phase last_heartbeat_epoch=0

    target_path="${RECOVERY_DIR%/}/${archive}"
    decrypt_path="${target_path}.dec"
    marker="${STATE_DIR%/}/${archive}.done"

    # Existing completed recovery. v1.1 markers are upgraded in-place by
    # running only post-verification; the 45GB archive is not re-downloaded.
    if recovery_marker_base_valid "$marker" "$target_path" "$archive"; then
        size="$(get_file_size "$target_path")"

        if post_verify_marker_valid "$marker"; then
            log INFO "archive already successfully recovered and verified: archive=$archive size=$size"
            [[ -f "$decrypt_path" ]] && log WARNING "unexpected decrypt file exists beside valid archive: $decrypt_path"
            if [[ "$(read_marker_value "$marker" post_verify_mode)" == "all" ]]; then
                cleanup_all_checkpoint "$target_path"
            fi
            return 0
        fi

        if bool_yes "$POST_VERIFY"; then
            log INFO "archive recovery marker is valid but post-verification is missing/stale; verifying existing local archive"
            post_verify_archive "$target_path" || return 1
            create_done_marker "$target_path" "$archive" "$marker"
            log INFO "existing recovered archive upgraded to v${VERSION} verified marker without re-download"
            return 0
        fi

        log INFO "archive already successfully recovered: archive=$archive size=$size"
        return 0
    fi

    if [[ -f "$marker" || -f "$target_path" || -f "$decrypt_path" ]]; then
        preserve_previous_recovery "$target_path" "$decrypt_path" "$marker" || return 1
    fi

    check_free_space "$RECOVERY_DIR" || return 1
    check_free_space "$TEMP_WORKSPACE" || return 1

    log INFO "============================================================"
    log INFO "recovery starting"
    log INFO "version=$VERSION"
    log INFO "archive=$archive"
    log INFO "RecoveryDir=$RECOVERY_DIR"
    log INFO "TemporaryWorkspace=$TEMP_WORKSPACE"
    log INFO "EncryptionKeyFile=$ENCRYPTION_KEY_FILE"
    log INFO "POST_VERIFY=$POST_VERIFY"
    log INFO "POST_VERIFY_MODE=${POST_VERIFY_MODE:-disabled}"
    log INFO "POST_VERIFY_EXTRACT_INNER=${POST_VERIFY_EXTRACT_INNER:-no}"
    log INFO "POST_VERIFY_REQUIRE_REGULAR_FILE=${POST_VERIFY_REQUIRE_REGULAR_FILE:-yes}"
    log INFO "POST_VERIFY_REQUIRE_NONEMPTY=${POST_VERIFY_REQUIRE_NONEMPTY:-no}"
    log INFO "============================================================"

    start_epoch="$(date +%s)"
    last_heartbeat_epoch="$start_epoch"

    setsid \
        "$S3S_BIN" recovery \
            -AccessKey "$ACCESS_KEY" \
            -SecretKey "$SECRET_KEY" \
            -TargetPath "$archive" \
            -RecoveryDir "${RECOVERY_DIR%/}/" \
            -EncryptionKeyFilePath "$ENCRYPTION_KEY_FILE" \
            -TemporaryWorksapce "${TEMP_WORKSPACE%/}/" \
        > >(tee -a "$RUN_LOG") \
        2>&1 &

    RECOVERY_PID=$!
    log INFO "recovery process started PID=$RECOVERY_PID"

    while kill -0 "$RECOVERY_PID" 2>/dev/null; do
        now_epoch="$(date +%s)"
        elapsed=$((now_epoch - start_epoch))

        if (( elapsed >= RECOVERY_TIMEOUT_SEC )); then
            log ERROR "recovery timeout after ${elapsed}s; terminating PID=$RECOVERY_PID"
            kill -TERM -- "-${RECOVERY_PID}" 2>/dev/null || true
            sleep 10
            if kill -0 "$RECOVERY_PID" 2>/dev/null; then
                log WARNING "recovery did not terminate; sending SIGKILL"
                kill -KILL -- "-${RECOVERY_PID}" 2>/dev/null || true
            fi
            wait "$RECOVERY_PID" 2>/dev/null || true
            RECOVERY_PID=""
            return 124
        fi

        size="$(get_file_size "$target_path")"
        decrypt_size="$(get_file_size "$decrypt_path")"

        if [[ -f "$decrypt_path" ]]; then
            new_phase="DECRYPT"
        elif [[ "$phase" == "DECRYPT" || "$phase" == "FINALIZE" ]]; then
            new_phase="FINALIZE"
        elif (( size > 0 )); then
            new_phase="DOWNLOAD"
        else
            new_phase="WAITING"
        fi

        if [[ "$new_phase" != "$phase" ]]; then
            log INFO "phase changed: ${phase} -> ${new_phase} archive=$archive elapsed=${elapsed}s"
            phase="$new_phase"
        fi

        case "$phase" in
            DOWNLOAD)
                if [[ "$size" != "$last_size" ]]; then
                    log INFO "download in-progress: archive=$archive size=$size bytes elapsed=${elapsed}s"
                    last_size="$size"
                    last_heartbeat_epoch="$now_epoch"
                fi
                ;;
            DECRYPT)
                if [[ "$decrypt_size" != "$last_decrypt_size" ]]; then
                    log INFO "decrypt in-progress: archive=$archive encrypted_size=$size decrypt_size=$decrypt_size bytes elapsed=${elapsed}s"
                    last_decrypt_size="$decrypt_size"
                    last_heartbeat_epoch="$now_epoch"
                fi
                ;;
            FINALIZE)
                if [[ "$size" != "$last_size" ]]; then
                    log INFO "finalize in-progress: archive=$archive final_size=$size bytes elapsed=${elapsed}s"
                    last_size="$size"
                    last_heartbeat_epoch="$now_epoch"
                fi
                ;;
            WAITING)
                if (( now_epoch - last_heartbeat_epoch >= MONITOR_HEARTBEAT_SEC )); then
                    log INFO "recovery waiting-for-output: archive=$archive elapsed=${elapsed}s"
                    last_heartbeat_epoch="$now_epoch"
                fi
                ;;
        esac

        if (( now_epoch - last_heartbeat_epoch >= MONITOR_HEARTBEAT_SEC )); then
            log INFO "recovery heartbeat: archive=$archive phase=$phase size=$size decrypt_size=$decrypt_size elapsed=${elapsed}s"
            last_heartbeat_epoch="$now_epoch"
        fi

        sleep "$MONITOR_INTERVAL_SEC"
    done

    wait "$RECOVERY_PID"
    rc=$?
    RECOVERY_PID=""

    if (( rc != 0 )); then
        log ERROR "recovery command failed archive=$archive rc=$rc"
        return "$rc"
    fi

    log INFO "recovery command completed successfully archive=$archive"

    [[ -f "$target_path" ]] || {
        log ERROR "recovery returned success but final target does not exist: $target_path"
        return 1
    }
    [[ -s "$target_path" ]] || {
        log ERROR "recovery returned success but final target is empty: $target_path"
        return 1
    }
    [[ ! -f "$decrypt_path" ]] || {
        log ERROR "recovery returned success but decrypt temporary file still exists: $decrypt_path"
        return 1
    }

    verify_file_stable "$target_path" || return 1
    verify_tar "$target_path" || return 1

    if bool_yes "$POST_VERIFY"; then
        post_verify_archive "$target_path" || return 1
    else
        POST_VERIFY_RESULT="DISABLED"
    fi

    create_done_marker "$target_path" "$archive" "$marker"

    size="$(get_file_size "$target_path")"
    elapsed=$(( $(date +%s) - start_epoch ))

    log INFO "============================================================"
    log INFO "RECOVERY SUCCESS"
    log INFO "archive=$archive"
    log INFO "size=$size bytes"
    log INFO "elapsed=${elapsed} seconds"
    log INFO "path=$target_path"
    log INFO "post_verify=${POST_VERIFY_RESULT:-DISABLED}"
    log INFO "post_verify_mode=${POST_VERIFY_MODE_USED:-${POST_VERIFY_MODE:-disabled}}"
    log INFO "post_verify_verified=${POST_VERIFY_VERIFIED:-0}/${POST_VERIFY_TOTAL:-0}"
    log INFO "post_verify_member=${POST_VERIFY_MEMBER:-none}"
    log INFO "post_verify_extract=${POST_VERIFY_EXTRACT_RESULT:-DISABLED}"
    log INFO "post_verify_regular_files=${POST_VERIFY_REGULAR_FILES:-0}"
    log INFO "post_verify_readable_files=${POST_VERIFY_READABLE_FILES:-0}"
    log INFO "============================================================"
    return 0
}

show_status()
{
    local marker archive path marker_size actual_size status verify_state verify_mode verify_total verify_verified verify_failed verify_extract regular_files readable_files checkpoint checkpoint_count
    local found=0

    printf 'HiCloud Recovery v%s\n\n' "$VERSION"
    printf 'Recovery directory:\n  %s\n\n' "$RECOVERY_DIR"
    if bool_yes "$POST_VERIFY"; then
        printf 'Configured post-verify mode:\n  %s\n\n' "$POST_VERIFY_MODE"
    fi
    printf 'Completed archives:\n\n'

    while IFS= read -r marker; do
        [[ -n "$marker" ]] || continue
        found=1

        archive="$(read_marker_value "$marker" archive)"
        path="$(read_marker_value "$marker" path)"
        marker_size="$(read_marker_value "$marker" size_bytes)"
        actual_size="$(get_file_size "$path")"
        verify_state="$(read_marker_value "$marker" post_verify)"
        verify_mode="$(read_marker_value "$marker" post_verify_mode)"
        verify_total="$(read_marker_value "$marker" post_verify_total)"
        verify_verified="$(read_marker_value "$marker" post_verify_verified)"
        verify_failed="$(read_marker_value "$marker" post_verify_failed)"
        verify_extract="$(read_marker_value "$marker" post_verify_extract)"
        regular_files="$(read_marker_value "$marker" post_verify_regular_files_total)"
        readable_files="$(read_marker_value "$marker" post_verify_readable_files_total)"
        checkpoint="$(checkpoint_path_for_archive "$path")"
        checkpoint_count=0
        if [[ -f "$checkpoint" ]]; then
            checkpoint_count="$(checkpoint_completed_count "$checkpoint")"
        fi

        # v1.2 marker compatibility: absence of post_verify_mode intentionally
        # becomes VERIFY_PENDING so v1.3 can upgrade it without re-downloading.
        [[ -n "$verify_state" ]] || verify_state="$(read_marker_value "$marker" sample_verify)"

        if ! recovery_marker_base_valid "$marker" "$path" "$archive"; then
            status="INVALID"
        elif post_verify_marker_valid "$marker"; then
            status="VALID"
        elif bool_yes "$POST_VERIFY"; then
            status="VERIFY_PENDING"
        else
            status="VALID"
        fi

        printf '  %-20s status=%-14s marker_size=%s actual_size=%s verify=%s mode=%s verified=%s/%s failed=%s extract=%s files=%s/%s checkpoint=%s\n' \
            "$archive" \
            "$status" \
            "${marker_size:-unknown}" \
            "${actual_size:-0}" \
            "${verify_state:-none}" \
            "${verify_mode:-legacy}" \
            "${verify_verified:-0}" \
            "${verify_total:-0}" \
            "${verify_failed:-0}" \
            "${verify_extract:-legacy}" \
            "${readable_files:-0}" \
            "${regular_files:-0}" \
            "${checkpoint_count:-0}"
    done < <(
        find "$STATE_DIR" -maxdepth 1 -type f -name '*.tar.done' -print 2>/dev/null |
        LC_ALL=C sort -r
    )

    (( found == 1 )) || printf '  No completed archive found.\n'
}

ACTION="${1:-run}"

case "$ACTION" in
    list)
        fetch_cloud_list || exit 1
        parse_cloud_files || exit 1
        printf '\nCloud backup files:\n\n'
        printf '%s\n' "$FILES"
        ;;

    latest)
        fetch_cloud_list || exit 1
        parse_cloud_files || exit 1
        select_latest_file || exit 1
        echo "$LATEST_FILE"
        ;;

    run)
        acquire_lock || exit 0
        log INFO "scheduled recovery job started version=$VERSION"
        fetch_cloud_list || exit 1
        parse_cloud_files || exit 1
        select_latest_file || exit 1
        recover_latest "$LATEST_FILE"
        rc=$?
        if (( rc == 0 )); then
            log INFO "scheduled recovery job finished successfully"
        else
            log ERROR "scheduled recovery job failed rc=$rc"
        fi
        exit "$rc"
        ;;

    status)
        show_status
        ;;

    version|--version|-V)
        echo "hicloud_latest_recovery.sh v${VERSION}"
        ;;

    *)
        cat <<USAGE
HiCloud Secure Storage Recovery v${VERSION}

Usage:
  $0 run
  $0 list
  $0 latest
  $0 status
  $0 version

run performs:
  cloud list -> latest YYYYMMDD.tar -> recovery -> stable check
  -> POST_VERIFY_MODE=smallest|random|all selection
  -> pinned GPG signature verify -> three GPG decrypt layers
  -> zstd -t -> inner tar list verify -> safe actual extraction
  -> regular-file/readability checks
  -> large-file progress/timeout -> all-mode checkpoint/resume -> completion marker

Configuration:
  $CONFIG_FILE
USAGE
        exit 2
        ;;
esac
