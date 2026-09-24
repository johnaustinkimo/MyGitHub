#!/usr/bin/env bash
# wsmanager_ts4500Toscalari3_v1.4.sh
# Version: 1.4 - TS4500 v1.6 restore mbuffer controls + Scalar i3 v1.4 write controls
# websocketd allow-list dispatcher for TS4500 -> NFS -> Scalar i3 operations UI.
set -uo pipefail
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root
USER=root
LOGNAME=root
SHELL=/bin/bash
export PATH HOME USER LOGNAME SHELL

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOGGP_HELPER="${LOGGP_HELPER:-${SCRIPT_DIR}/logGP_it.sh}"
TS4500_SCRIPT="${TS4500_SCRIPT:-${SCRIPT_DIR}/ts4500_ops_v1.6.sh}"
SCALARI3_SCRIPT="${SCALARI3_SCRIPT:-${SCRIPT_DIR}/scalari3_tape_write_v1.4.sh}"
BASE64_BIN="${BASE64_BIN:-$(command -v base64 2>/dev/null || true)}"
LOGGER_BIN="${LOGGER_BIN:-$(command -v logger 2>/dev/null || true)}"

AUTHENTICATED=0
AUTH_USER=""
AUTH_ROLE=""
CHILD_PID=""

audit(){ [[ -n "$LOGGER_BIN" ]] && "$LOGGER_BIN" -p daemon.info -t ts4500_scalar_ws -- "$*" 2>/dev/null || true; }
emit(){ printf '%s\n' "$*"; }
need_exec(){ [[ -x "$1" ]] || { emit "@ERROR|$2|required executable not found: $1"; return 1; }; }
valid_id(){ [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,80}$ ]]; }
valid_volser(){ [[ -z "${1:-}" || "${1:-}" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
stop_child(){ if [[ -n "${CHILD_PID:-}" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then kill -TERM "$CHILD_PID" 2>/dev/null || true; fi; }
trap stop_child INT TERM HUP

safe_b64_decode(){
    local encoded="${1:-}" max_len="${2:-1024}" decoded
    [[ -n "$encoded" ]] || { printf ''; return 0; }
    [[ -n "$BASE64_BIN" ]] || return 1
    [[ ${#encoded} -le 8192 ]] || return 1
    decoded="$(printf '%s' "$encoded" | "$BASE64_BIN" -d 2>/dev/null)" || return 1
    [[ ${#decoded} -le "$max_len" ]] || return 1
    [[ "$decoded" != *$'\n'* && "$decoded" != *$'\r'* ]] || return 1
    printf '%s' "$decoded"
}

kv_get(){
    local payload="$1" key="$2" item
    IFS=';' read -ra _items <<< "$payload"
    for item in "${_items[@]}"; do
        [[ "${item%%=*}" == "$key" ]] && { printf '%s' "${item#*=}"; return 0; }
    done
    printf ''
}

valid_payload_chars(){ case "${1:-}" in *[!A-Za-z0-9._=/\;:-]*) return 1 ;; *) return 0 ;; esac; }

handle_auth(){
    local verb="${1:-}" a1="${2:-}" a2="${3:-}"
    case "$verb" in
      LOGIN)
        local user pass result status role
        [[ -x "$LOGGP_HELPER" ]] || { emit "@AUTH|ERR|authentication helper unavailable"; return; }
        user="$(safe_b64_decode "$a1" 128)" || { emit "@AUTH|ERR|invalid username encoding"; return; }
        pass="$(safe_b64_decode "$a2" 256)" || { emit "@AUTH|ERR|invalid password encoding"; return; }
        [[ -n "$user" && -n "$pass" ]] || { emit "@AUTH|ERR|username/password required"; return; }
        result="$("$LOGGP_HELPER" loginQuery "$user" "$pass" 2>/dev/null | tail -n 1)"
        status="${result%%|*}"; role="${result#*|}"
        if [[ "$status" == "1" ]]; then
            AUTHENTICATED=1; AUTH_USER="$user"; AUTH_ROLE="${role:-USER}"
            audit "event=AUTH_SUCCESS user=\"$AUTH_USER\" role=$AUTH_ROLE"
            emit "@AUTH|OK|$AUTH_ROLE"
        else
            audit "event=AUTH_FAILURE user=\"$user\""
            AUTHENTICATED=0; AUTH_USER=""; AUTH_ROLE=""
            emit "@AUTH|ERR|authentication failed"
        fi
        unset pass result
        ;;
      LOGOUT)
        audit "event=AUTH_LOGOUT user=\"$AUTH_USER\" role=$AUTH_ROLE"
        AUTHENTICATED=0; AUTH_USER=""; AUTH_ROLE=""
        emit "@AUTH|LOGOUT|OK"
        ;;
      *) emit "@AUTH|ERR|unsupported authentication request" ;;
    esac
}

run_cmd(){
    local id="$1" domain="$2" action="$3" enc="${4:-}"
    local payload="" script="" label="" rc=1 volser="" after="" yes="" verify="" keep="" entries="" timeout="" preserve="" heartbeat="" read_mode="" write_mode="" buffer_mem="" block_size=""
    (( AUTHENTICATED == 1 )) || { emit "@ERROR|$id|authentication required"; return; }

    payload="$(safe_b64_decode "$enc" 512)" || { emit "@ERROR|$id|invalid action argument encoding"; return; }
    valid_payload_chars "$payload" || { emit "@ERROR|$id|invalid action argument characters"; return; }

    volser="$(kv_get "$payload" volser)"
    after="$(kv_get "$payload" after)"
    yes="$(kv_get "$payload" yes)"
    verify="$(kv_get "$payload" verify)"
    keep="$(kv_get "$payload" keep)"
    entries="$(kv_get "$payload" entries)"
    timeout="$(kv_get "$payload" timeout)"
    preserve="$(kv_get "$payload" preserve)"
    heartbeat="$(kv_get "$payload" heartbeat)"
    read_mode="$(kv_get "$payload" read_mode)"
    write_mode="$(kv_get "$payload" write_mode)"
    buffer_mem="$(kv_get "$payload" buffer_mem)"
    block_size="$(kv_get "$payload" block_size)"

    valid_volser "$volser" || { emit "@ERROR|$id|invalid VOLSER"; return; }
    [[ -z "$after" || "$after" =~ ^(keep|unload|export)$ ]] || { emit "@ERROR|$id|invalid after mode"; return; }
    [[ -z "$verify" || "$verify" =~ ^(none|probe|full)$ ]] || { emit "@ERROR|$id|invalid verify mode"; return; }
    [[ -z "$yes" || "$yes" == "1" ]] || { emit "@ERROR|$id|invalid yes flag"; return; }
    [[ -z "$keep" || "$keep" == "1" ]] || { emit "@ERROR|$id|invalid keep flag"; return; }
    [[ -z "$preserve" || "$preserve" == "1" ]] || { emit "@ERROR|$id|invalid preserve flag"; return; }
    [[ -z "$entries" || "$entries" =~ ^[0-9]{1,3}$ ]] || { emit "@ERROR|$id|invalid probe entries"; return; }
    [[ -z "$timeout" || "$timeout" =~ ^[0-9]{1,4}$ ]] || { emit "@ERROR|$id|invalid probe timeout"; return; }
    [[ -z "$heartbeat" || "$heartbeat" =~ ^[0-9]{1,4}$ ]] || { emit "@ERROR|$id|invalid heartbeat seconds"; return; }
    if [[ -n "$heartbeat" ]] && (( 10#$heartbeat < 5 || 10#$heartbeat > 3600 )); then
        emit "@ERROR|$id|heartbeat seconds must be between 5 and 3600"; return
    fi
    [[ -z "$read_mode" || "$read_mode" =~ ^(mbuffer|direct)$ ]] || { emit "@ERROR|$id|invalid read mode"; return; }
    [[ -z "$write_mode" || "$write_mode" =~ ^(mbuffer|direct)$ ]] || { emit "@ERROR|$id|invalid write mode"; return; }
    [[ -z "$buffer_mem" || "$buffer_mem" =~ ^[1-9][0-9]*[kKmMgGtT]?$ ]] || { emit "@ERROR|$id|invalid buffer memory size"; return; }
    [[ -z "$block_size" || "$block_size" =~ ^[1-9][0-9]*[kKmMgGtT]?$ ]] || { emit "@ERROR|$id|invalid block size"; return; }

    case "$domain:$action" in
      TS4500:STATUS)          script="$TS4500_SCRIPT"; label="TS4500 / Status";          set -- status ;;
      TS4500:DRIVE_CHECK)     script="$TS4500_SCRIPT"; label="TS4500 / Drive Check";     set -- drive-check ;;
      TS4500:CANDIDATES)      script="$TS4500_SCRIPT"; label="TS4500 / Candidates";      set -- candidates ;;
      TS4500:SELECT)          script="$TS4500_SCRIPT"; label="TS4500 / Select Tape";     set -- select ;;
      TS4500:LAST_UNLOADED)   script="$TS4500_SCRIPT"; label="TS4500 / Last Unloaded";   set -- last-unloaded ;;
      TS4500:DRIVE_SUMMARY)   script="$TS4500_SCRIPT"; label="TS4500 / Drive Summary";   set -- drive-summary ;;
      TS4500:CARTRIDGES)      script="$TS4500_SCRIPT"; label="TS4500 / Cartridges";      set -- cartridges ;;
      TS4500:TAPE_STATUS)     script="$TS4500_SCRIPT"; label="TS4500 / Tape Status";     set -- tape-status; [[ -n "$volser" ]] && set -- "$@" "$volser" ;;
      TS4500:TAPE_PROBE)
        script="$TS4500_SCRIPT"; label="TS4500 / Tape Probe"; set -- tape-probe
        [[ -n "$volser" ]] && set -- "$@" "$volser"
        [[ -n "$entries" ]] && set -- "$@" --entries "$entries"
        [[ -n "$timeout" ]] && set -- "$@" --timeout "$timeout"
        ;;
      TS4500:LOAD)            script="$TS4500_SCRIPT"; label="TS4500 / Load";            set -- load; [[ -n "$volser" ]] && set -- "$@" "$volser" ;;
      TS4500:UNLOAD)          script="$TS4500_SCRIPT"; label="TS4500 / Unload";          set -- unload; [[ -n "$volser" ]] && set -- "$@" "$volser" ;;
      TS4500:EXPORT)
        script="$TS4500_SCRIPT"; label="TS4500 / Export to I/O Slot"; set -- export
        [[ -n "$volser" ]] && set -- "$@" "$volser"
        set -- "$@" --yes
        ;;
      TS4500:UNLOAD_EXPORT)
        script="$TS4500_SCRIPT"; label="TS4500 / Unload + Export"; set -- unload-export
        [[ -n "$volser" ]] && set -- "$@" "$volser"
        set -- "$@" --yes
        ;;
      TS4500:TAPE_READ)
        script="$TS4500_SCRIPT"; label="TS4500 / Tape Read to NFS"; set -- tape-read
        [[ -n "$volser" ]] && set -- "$@" "$volser"
        [[ "$preserve" == "1" ]] && set -- "$@" --preserve-owner
        read_mode="${read_mode:-mbuffer}"
        if [[ "$read_mode" == "direct" ]]; then
          set -- "$@" --no-mbuffer
        else
          set -- "$@" --mbuffer
          [[ -n "$buffer_mem" ]] && set -- "$@" --buffer-mem "$buffer_mem"
          [[ -n "$block_size" ]] && set -- "$@" --block-size "$block_size"
        fi
        ;;
      TS4500:RECOVER)
        script="$TS4500_SCRIPT"; label="TS4500 / Production Recovery"; set -- recover
        [[ -n "$volser" ]] && set -- "$@" "$volser"
        [[ -n "$entries" ]] && set -- "$@" --probe-entries "$entries"
        [[ -n "$timeout" ]] && set -- "$@" --probe-timeout "$timeout"
        [[ "$preserve" == "1" ]] && set -- "$@" --preserve-owner
        read_mode="${read_mode:-mbuffer}"
        if [[ "$read_mode" == "direct" ]]; then
          set -- "$@" --no-mbuffer
        else
          set -- "$@" --mbuffer
          [[ -n "$buffer_mem" ]] && set -- "$@" --buffer-mem "$buffer_mem"
          [[ -n "$block_size" ]] && set -- "$@" --block-size "$block_size"
        fi
        after="${after:-unload}"
        set -- "$@" --after "$after"
        [[ "$after" == "export" ]] && set -- "$@" --yes
        ;;
      TS4500:TEST_CYCLE)      script="$TS4500_SCRIPT"; label="TS4500 / Test Cycle";      set -- test-cycle; [[ -n "$volser" ]] && set -- "$@" "$volser" ;;

      SCALARI3:SCAN)          script="$SCALARI3_SCRIPT"; label="Scalar i3 / Scan NFS";      set -- scan ;;
      SCALARI3:NFS_STATUS)    script="$SCALARI3_SCRIPT"; label="Scalar i3 / NFS Status";    set -- nfs-status ;;
      SCALARI3:TAPE_STATUS)   script="$SCALARI3_SCRIPT"; label="Scalar i3 / Tape Status";   set -- tape-status ;;
      SCALARI3:DRIVE_EMPTY)   script="$SCALARI3_SCRIPT"; label="Scalar i3 / Drive Empty";   set -- drive-empty ;;
      SCALARI3:PRECHECK)      script="$SCALARI3_SCRIPT"; label="Scalar i3 / Precheck";      set -- precheck ;;
      SCALARI3:LOAD)          script="$SCALARI3_SCRIPT"; label="Scalar i3 / Load Tape";     set -- load ;;
      SCALARI3:UNLOAD)        script="$SCALARI3_SCRIPT"; label="Scalar i3 / Unload Tape";   set -- unload ;;
      SCALARI3:WRITE)
        script="$SCALARI3_SCRIPT"; label="Scalar i3 / Write Tape"; set -- write
        verify="${verify:-probe}"; set -- "$@" --verify "$verify"
        [[ -n "$entries" ]] && set -- "$@" --probe-entries "$entries"
        [[ -n "$heartbeat" ]] && set -- "$@" --heartbeat-sec "$heartbeat"
        write_mode="${write_mode:-mbuffer}"
        if [[ "$write_mode" == "direct" ]]; then
          set -- "$@" --no-mbuffer
        else
          [[ -n "$buffer_mem" ]] && set -- "$@" --buffer-mem "$buffer_mem"
          [[ -n "$block_size" ]] && set -- "$@" --block-size "$block_size"
        fi
        ;;
      SCALARI3:RUN)
        script="$SCALARI3_SCRIPT"; label="Scalar i3 / Production Write"; set -- run
        verify="${verify:-probe}"; set -- "$@" --verify "$verify"
        [[ -n "$entries" ]] && set -- "$@" --probe-entries "$entries"
        [[ -n "$heartbeat" ]] && set -- "$@" --heartbeat-sec "$heartbeat"
        write_mode="${write_mode:-mbuffer}"
        if [[ "$write_mode" == "direct" ]]; then
          set -- "$@" --no-mbuffer
        else
          [[ -n "$buffer_mem" ]] && set -- "$@" --buffer-mem "$buffer_mem"
          [[ -n "$block_size" ]] && set -- "$@" --block-size "$block_size"
        fi
        [[ "$keep" == "1" ]] && set -- "$@" --keep
        ;;
      *) emit "@ERROR|$id|unsupported action"; return ;;
    esac

    need_exec "$script" "$id" || return
    emit "@BEGIN|$id|$label"
    audit "event=ACTION_BEGIN user=\"$AUTH_USER\" role=$AUTH_ROLE domain=$domain action=$action request=$id"

    # CLI wrappers intentionally write INFO/WARN/ERROR diagnostics to stderr.
    # websocketd forwards this dispatcher's stdout to the browser, so merge the
    # child stderr into stdout to preserve the same messages seen in a terminal.
    "$script" "$@" 2>&1 &
    CHILD_PID=$!
    wait "$CHILD_PID"
    rc=$?
    CHILD_PID=""

    audit "event=ACTION_END user=\"$AUTH_USER\" role=$AUTH_ROLE domain=$domain action=$action request=$id rc=$rc"
    emit "@END|$id|$rc"
}

while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    [[ ${#line} -le 8192 ]] || { emit "@ERROR|-|request too large"; continue; }

    if [[ "$line" == @AUTH\|* ]]; then
        IFS='|' read -r m verb a1 a2 extra <<< "$line"
        [[ "$m" == "@AUTH" && -z "${extra:-}" ]] || { emit "@AUTH|ERR|malformed authentication request"; continue; }
        handle_auth "${verb:-}" "${a1:-}" "${a2:-}"
        continue
    fi

    if [[ "$line" == @ACTION\|* ]]; then
        IFS='|' read -r m id domain action arg extra <<< "$line"
        [[ "$m" == "@ACTION" && -z "${extra:-}" ]] || { emit "@ERROR|-|malformed action request"; continue; }
        valid_id "$id" || { emit "@ERROR|-|invalid request id"; continue; }
        run_cmd "$id" "${domain^^}" "${action^^}" "${arg:-}"
        continue
    fi

    emit "@ERROR|-|unsupported protocol"
done
exit 0