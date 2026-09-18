#!/usr/bin/env bash
# wsmanager3.sh - allow-list websocketd dispatcher for HiCloud UI v2
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOGGP_HELPER="${LOGGP_HELPER:-${SCRIPT_DIR}/logGP_it.sh}"
UPLOAD_SCRIPT="${UPLOAD_SCRIPT:-${SCRIPT_DIR}/hicloud_latest_upload.sh}"
RECOVERY_SCRIPT="${RECOVERY_SCRIPT:-${SCRIPT_DIR}/hicloud_latest_recovery.sh}"
BASE64_BIN="${BASE64_BIN:-$(command -v base64 2>/dev/null || true)}"
LOGGER_BIN="${LOGGER_BIN:-$(command -v logger 2>/dev/null || true)}"

AUTHENTICATED=0
AUTH_USER=""
AUTH_ROLE=""
CHILD_PID=""

audit(){ [[ -n "$LOGGER_BIN" ]] && "$LOGGER_BIN" -p daemon.info -t wsmanager3 -- "$*" 2>/dev/null || true; }
emit(){ printf '%s\n' "$*"; }

safe_b64_decode(){
    local encoded="${1:-}" max_len="${2:-1024}" decoded
    [[ -n "$BASE64_BIN" ]] || return 1
    [[ ${#encoded} -le 4096 ]] || return 1
    decoded="$(printf '%s' "$encoded" | "$BASE64_BIN" -d 2>/dev/null)" || return 1
    [[ ${#decoded} -le "$max_len" ]] || return 1
    [[ "$decoded" != *$'\n'* && "$decoded" != *$'\r'* ]] || return 1
    printf '%s' "$decoded"
}
valid_id(){ [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,80}$ ]]; }
valid_archive(){ [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
need_exec(){ [[ -x "$1" ]] || { emit "@ERROR|$2|required executable not found: $1"; return 1; }; }
stop_child(){ if [[ -n "${CHILD_PID:-}" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then kill -TERM "$CHILD_PID" 2>/dev/null || true; fi; }
trap stop_child INT TERM HUP

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
        emit "@AUTH|OK|LOGOUT"
        ;;
      *) emit "@AUTH|ERR|unsupported authentication request" ;;
    esac
}

run_cmd(){
    local id="$1" domain="$2" action="$3" enc="${4:-}"
    local script label arg="" rc=1
    (( AUTHENTICATED == 1 )) || { emit "@ERROR|$id|authentication required"; return; }

    case "$domain:$action" in
      UPLOAD:CHECK_SOURCE) script="$UPLOAD_SCRIPT"; label="Upload / Check Source"; set -- check-source ;;
      UPLOAD:LIST)         script="$UPLOAD_SCRIPT"; label="Upload / Cloud List";   set -- list ;;
      UPLOAD:STATUS)       script="$UPLOAD_SCRIPT"; label="Upload / Status";       set -- status ;;
      UPLOAD:RUN)
        script="$UPLOAD_SCRIPT"; label="Upload / Run"
        if [[ -n "$enc" ]]; then
            arg="$(safe_b64_decode "$enc" 128)" || { emit "@ERROR|$id|invalid archive encoding"; return; }
            arg="${arg%.tar.gz}"; arg="${arg%.tar}"
            valid_archive "$arg" || { emit "@ERROR|$id|invalid archive name"; return; }
            set -- run "$arg"
        else
            set -- run
        fi
        ;;
      RECOVERY:LIST)   script="$RECOVERY_SCRIPT"; label="Recovery / Cloud List";  set -- list ;;
      RECOVERY:LATEST) script="$RECOVERY_SCRIPT"; label="Recovery / Latest";      set -- latest ;;
      RECOVERY:STATUS) script="$RECOVERY_SCRIPT"; label="Recovery / Status";      set -- status ;;
      RECOVERY:RUN)
        [[ -z "$enc" ]] || { emit "@ERROR|$id|recovery RUN does not accept arguments"; return; }
        script="$RECOVERY_SCRIPT"; label="Recovery / Run Latest"; set -- run
        ;;
      *) emit "@ERROR|$id|unsupported action"; return ;;
    esac

    need_exec "$script" "$id" || return
    emit "@BEGIN|$id|$label"
    audit "event=ACTION_BEGIN user=\"$AUTH_USER\" role=$AUTH_ROLE domain=$domain action=$action request=$id"

    "$script" "$@" &
    CHILD_PID=$!
    wait "$CHILD_PID"
    rc=$?
    CHILD_PID=""

    audit "event=ACTION_END user=\"$AUTH_USER\" domain=$domain action=$action request=$id rc=$rc"
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
