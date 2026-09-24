#!/usr/bin/env bash
# tape_to_tape_migrate v1.1 performance module
# Drop-in enhancement for v1.0 raw tape-file copy.
#
# Adds:
#   --copy-engine auto|dd-mbuffer|dd
#   --mbuffer-bin PATH
#   --buffer-mem SIZE
#   --block-size SIZE
#   --dd-block-size SIZE
#   --no-mbuffer
#
# Recommended defaults are aligned with scalari3_tape_write_v1.4.sh.

COPY_ENGINE="${T2T_COPY_ENGINE:-auto}"          # auto|dd-mbuffer|dd
MBUFFER_BIN="${T2T_MBUFFER_BIN:-mbuffer}"
BUFFER_MEM="${T2T_BUFFER_MEM:-6G}"
BLOCK_SIZE="${T2T_BLOCK_SIZE:-1M}"
DD_BLOCK_SIZE="${T2T_DD_BLOCK_SIZE:-1M}"

# Optional runtime metrics populated by copy_tape_file_fast().
COPY_SELECTED_ENGINE=""
COPY_SOURCE_RC=0
COPY_MBUFFER_RC=0
COPY_DEST_RC=0
COPY_ELAPSED_SEC=0

_t2t_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$@"
    else
        printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}

_t2t_warn() {
    if declare -F warn >/dev/null 2>&1; then
        warn "$@"
    else
        printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}

_t2t_err() {
    if declare -F err >/dev/null 2>&1; then
        err "$@"
    else
        printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}

validate_copy_engine_config() {
    case "$COPY_ENGINE" in
        auto|dd-mbuffer|dd) ;;
        *)
            _t2t_err "Invalid copy engine: $COPY_ENGINE (expected auto|dd-mbuffer|dd)"
            return 2
            ;;
    esac

    command -v dd >/dev/null 2>&1 || {
        _t2t_err "Required command not found: dd"
        return 10
    }

    if [[ "$COPY_ENGINE" == "dd-mbuffer" ]]; then
        command -v "$MBUFFER_BIN" >/dev/null 2>&1 || {
            _t2t_err "mbuffer requested but not found: $MBUFFER_BIN"
            return 10
        }
    fi

    return 0
}

select_copy_engine() {
    case "$COPY_ENGINE" in
        dd)
            COPY_SELECTED_ENGINE="dd"
            ;;
        dd-mbuffer)
            command -v "$MBUFFER_BIN" >/dev/null 2>&1 || {
                _t2t_err "mbuffer requested but not found: $MBUFFER_BIN"
                return 10
            }
            COPY_SELECTED_ENGINE="dd-mbuffer"
            ;;
        auto)
            if command -v "$MBUFFER_BIN" >/dev/null 2>&1; then
                COPY_SELECTED_ENGINE="dd-mbuffer"
            else
                COPY_SELECTED_ENGINE="dd"
                _t2t_warn "mbuffer not found; falling back to dd-only copy"
            fi
            ;;
    esac
    return 0
}

show_copy_engine_config() {
    select_copy_engine || return $?
    printf 'Copy engine      : %s\n' "$COPY_SELECTED_ENGINE"
    printf 'dd block size    : %s\n' "$DD_BLOCK_SIZE"
    if [[ "$COPY_SELECTED_ENGINE" == "dd-mbuffer" ]]; then
        printf 'mbuffer binary   : %s\n' "$(command -v "$MBUFFER_BIN" 2>/dev/null || printf '%s' "$MBUFFER_BIN")"
        printf 'mbuffer memory   : %s\n' "$BUFFER_MEM"
        printf 'mbuffer block    : %s\n' "$BLOCK_SIZE"
    fi
}

# copy_tape_file_fast SOURCE_NOREWIND DEST_NOREWIND
#
# Copies exactly one tape file. EOF/filemark on SOURCE terminates the stream.
# Closing DEST after a successful write leaves the destination tape file closed
# in the same manner as the original v1.0 raw dd path.
copy_tape_file_fast() {
    local src="$1"
    local dst="$2"
    local start end had_errexit=0
    local -a ps

    case $- in
        *e*) had_errexit=1 ;;
    esac

    COPY_SOURCE_RC=0
    COPY_MBUFFER_RC=0
    COPY_DEST_RC=0
    COPY_ELAPSED_SEC=0

    validate_copy_engine_config || return $?
    select_copy_engine || return $?

    _t2t_log "Tape copy engine : $COPY_SELECTED_ENGINE"
    _t2t_log "Source           : $src"
    _t2t_log "Destination      : $dst"
    _t2t_log "dd block size    : $DD_BLOCK_SIZE"

    start=$(date +%s)

    if [[ "$COPY_SELECTED_ENGINE" == "dd-mbuffer" ]]; then
        _t2t_log "mbuffer memory   : $BUFFER_MEM"
        _t2t_log "mbuffer block    : $BLOCK_SIZE"

        # Do not use iflag=fullblock/conv=sync/oflag=direct with tape devices.
        # Keep the tape stream byte-exact and let mbuffer smooth drive-rate gaps.
        set +e
        dd if="$src" bs="$DD_BLOCK_SIZE" status=none \
        | "$MBUFFER_BIN" -m "$BUFFER_MEM" -s "$BLOCK_SIZE" -v 1 \
        | dd of="$dst" bs="$DD_BLOCK_SIZE" status=none
        ps=("${PIPESTATUS[@]}")
        (( had_errexit )) && set -e

        COPY_SOURCE_RC="${ps[0]:-99}"
        COPY_MBUFFER_RC="${ps[1]:-99}"
        COPY_DEST_RC="${ps[2]:-99}"

        if (( COPY_SOURCE_RC != 0 || COPY_MBUFFER_RC != 0 || COPY_DEST_RC != 0 )); then
            _t2t_err "Tape copy failed: source_dd_rc=$COPY_SOURCE_RC mbuffer_rc=$COPY_MBUFFER_RC dest_dd_rc=$COPY_DEST_RC"
            return 70
        fi
    else
        # Compatibility path matching v1.0 behavior, with configurable block size.
        set +e
        dd if="$src" of="$dst" bs="$DD_BLOCK_SIZE" status=progress
        COPY_SOURCE_RC=$?
        (( had_errexit )) && set -e
        COPY_DEST_RC="$COPY_SOURCE_RC"

        if (( COPY_SOURCE_RC != 0 )); then
            _t2t_err "Tape copy failed: dd_rc=$COPY_SOURCE_RC"
            return 70
        fi
    fi

    end=$(date +%s)
    COPY_ELAPSED_SEC=$(( end - start ))
    (( COPY_ELAPSED_SEC < 1 )) && COPY_ELAPSED_SEC=1

    _t2t_log "Tape copy completed: engine=$COPY_SELECTED_ENGINE elapsed=${COPY_ELAPSED_SEC}s"
    return 0
}

# Add these cases to the existing v1.0 argument parser:
#
#   --copy-engine)
#       COPY_ENGINE="$2"; shift 2 ;;
#   --mbuffer-bin)
#       MBUFFER_BIN="$2"; shift 2 ;;
#   --buffer-mem)
#       BUFFER_MEM="$2"; shift 2 ;;
#   --block-size)
#       BLOCK_SIZE="$2"; shift 2 ;;
#   --dd-block-size)
#       DD_BLOCK_SIZE="$2"; shift 2 ;;
#   --no-mbuffer)
#       COPY_ENGINE="dd"; shift ;;
#
# Replace the original v1.0 copy line:
#
#   dd if="$SRC_NOREWIND" of="$DST_NOREWIND" bs=1M status=progress
#
# with:
#
#   copy_tape_file_fast "$SRC_NOREWIND" "$DST_NOREWIND" || die 70 "Raw tape-file copy failed"
#
# Suggested usage additions:
#
#   --copy-engine MODE   auto | dd-mbuffer | dd. Default: auto
#   --mbuffer-bin PATH   mbuffer executable. Default: mbuffer
#   --buffer-mem SIZE    mbuffer memory. Default: 6G
#   --block-size SIZE    mbuffer I/O block size. Default: 1M
#   --dd-block-size SIZE dd I/O block size. Default: 1M
#   --no-mbuffer         force original dd-only copy path
#
# Example:
#   ./tape_to_tape_migrate_v1.1.sh migrate CDT018L7 \
#       --src-norewind /dev/IBMtape0n \
#       --dst-norewind /dev/tapedrv_testn \
#       --copy-engine dd-mbuffer \
#       --buffer-mem 6G \
#       --block-size 1M \
#       --dd-block-size 1M \
#       --yes --verify probe --dest-after keep
