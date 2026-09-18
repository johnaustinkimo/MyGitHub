#!/usr/bin/env bash
#
# wsmanager4.sh
# HiCloud Operations UI v3 WebSocket dispatcher.
#
# Security:
#   - no eval
#   - no arbitrary shell command execution
#   - backend authentication required for all actions
#   - strict allow-list for Upload/Recovery functions
#   - long RUN operations are detached through hicloud_jobctl
#

set -uo pipefail
umask 077

VERSION="4.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

LOGGP_HELPER="${LOGGP_HELPER:-${SCRIPT_DIR}/logGP_it.sh}"
UPLOAD_SCRIPT="${UPLOAD_SCRIPT:-${SCRIPT_DIR}/hicloud_latest_upload.sh}"
RECOVERY_SCRIPT="${RECOVERY_SCRIPT:-${SCRIPT_DIR}/hicloud_latest_recovery.sh}"
JOBCTL="${JOBCTL:-${SCRIPT_DIR}/hicloud_jobctl_v1.0.0.sh}"

BASE64_BIN="${BASE64_BIN:-$(command -v base64 2>/dev/null || true)}"
LOGGER_BIN="${LOGGER_BIN:-$(command -v logger 2>/dev/null || true)}"

AUTHENTICATED=0
AUTH_USER=""
AUTH_ROLE=""

audit()
{
    [[ -n "$LOGGER_BIN" ]] || return 0
    "$LOGGER_BIN" -p daemon.info -t wsmanager4 -- "$*" 2>/dev/null || true
}

emit()
{
    printf '%s\n' "$*"
}

safe_b64_decode()
{
    local encoded="${1:-}"
    local max_len="${2:-1024}"
    local decoded

    [[ -n "$BASE64_BIN" ]] || return 1

    if [[ -z "$encoded" ]]; then
        printf ''
        return 0
    fi

    [[ ${#encoded} -le 4096 ]] || return 1

    decoded="$(printf '%s' "$encoded" | "$BASE64_BIN" -d 2>/dev/null)" ||
        return 1

    [[ ${#decoded} -le "$max_len" ]] || return 1
    [[ "$decoded" != *$'\n'* && "$decoded" != *$'\r'* ]] || return 1

    printf '%s' "$decoded"
}

safe_b64_encode()
{
    local text="${1:-}"
    [[ -n "$BASE64_BIN" ]] || return 1
    printf '%s' "$text" | "$BASE64_BIN" -w 0 2>/dev/null
}

valid_request_id()
{
    [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,80}$ ]]
}

valid_job_id()
{
    [[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+-[A-Fa-f0-9]{6}$ ]]
}

valid_archive_name()
{
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

valid_user()
{
    [[ "${1:-}" =~ ^[A-Za-z0-9._@-]{1,128}$ ]]
}

require_auth()
{
    local req="${1:--}"
    if (( AUTHENTICATED != 1 )); then
        emit "@ERROR|$req|authentication required"
        return 1
    fi
}

handle_auth()
{
    local verb="${1:-}"
    local a1="${2:-}"
    local a2="${3:-}"

    case "$verb" in
        LOGIN)
            local user pass result status role

            [[ -x "$LOGGP_HELPER" ]] || {
                emit "@AUTH|ERR|authentication helper unavailable"
                return 0
            }

            user="$(safe_b64_decode "$a1" 128)" || {
                emit "@AUTH|ERR|invalid username encoding"
                return 0
            }
            pass="$(safe_b64_decode "$a2" 256)" || {
                emit "@AUTH|ERR|invalid password encoding"
                return 0
            }

            valid_user "$user" || {
                emit "@AUTH|ERR|invalid username"
                return 0
            }
            [[ -n "$pass" ]] || {
                emit "@AUTH|ERR|password required"
                return 0
            }

            result="$("$LOGGP_HELPER" loginQuery "$user" "$pass" 2>/dev/null | tail -n 1)"
            status="${result%%|*}"
            role="${result#*|}"

            unset pass

            if [[ "$status" == "1" ]]; then
                AUTHENTICATED=1
                AUTH_USER="$user"
                AUTH_ROLE="${role:-USER}"
                valid_user "$AUTH_ROLE" || AUTH_ROLE="USER"

                audit "event=AUTH_SUCCESS user=\"$AUTH_USER\" role=$AUTH_ROLE"
                emit "@AUTH|OK|$AUTH_ROLE"
            else
                audit "event=AUTH_FAILURE user=\"$user\""
                AUTHENTICATED=0
                AUTH_USER=""
                AUTH_ROLE=""
                emit "@AUTH|ERR|authentication failed"
            fi
            ;;

        LOGOUT)
            audit "event=AUTH_LOGOUT user=\"$AUTH_USER\" role=$AUTH_ROLE"
            AUTHENTICATED=0
            AUTH_USER=""
            AUTH_ROLE=""
            emit "@AUTH|OK|LOGOUT"
            ;;

        *)
            emit "@AUTH|ERR|unsupported authentication request"
            ;;
    esac
}

run_read_action()
{
    local req="$1"
    local domain="${2^^}"
    local action="${3^^}"
    local script label rc

    require_auth "$req" || return 0

    case "$domain:$action" in
        UPLOAD:CHECK_SOURCE)
            script="$UPLOAD_SCRIPT"; label="Upload / Check Source"; set -- check-source ;;
        UPLOAD:LIST)
            script="$UPLOAD_SCRIPT"; label="Upload / Cloud List"; set -- list ;;
        UPLOAD:STATUS)
            script="$UPLOAD_SCRIPT"; label="Upload / Status"; set -- status ;;
        RECOVERY:LIST)
            script="$RECOVERY_SCRIPT"; label="Recovery / Cloud List"; set -- list ;;
        RECOVERY:LATEST)
            script="$RECOVERY_SCRIPT"; label="Recovery / Latest"; set -- latest ;;
        RECOVERY:STATUS)
            script="$RECOVERY_SCRIPT"; label="Recovery / Status"; set -- status ;;
        *)
            emit "@ERROR|$req|unsupported read action"
            return 0
            ;;
    esac

    [[ -x "$script" ]] || {
        emit "@ERROR|$req|required executable unavailable"
        return 0
    }

    audit "event=READ_ACTION_BEGIN user=\"$AUTH_USER\" domain=$domain action=$action request=$req"
    emit "@BEGIN|$req|$label"

    "$script" "$@"
    rc=$?

    audit "event=READ_ACTION_END user=\"$AUTH_USER\" domain=$domain action=$action request=$req rc=$rc"
    emit "@END|$req|$rc"
}

job_start()
{
    local req="$1"
    local domain="${2^^}"
    local action="${3^^}"
    local encoded_arg="${4:-}"
    local arg=""
    local result status jobid launcher

    require_auth "$req" || return 0

    [[ -x "$JOBCTL" ]] || {
        emit "@ERROR|$req|job controller unavailable"
        return 0
    }

    [[ "$action" == "RUN" ]] || {
        emit "@ERROR|$req|unsupported job action"
        return 0
    }

    case "$domain" in
        UPLOAD)
            if [[ -n "$encoded_arg" ]]; then
                arg="$(safe_b64_decode "$encoded_arg" 128)" || {
                    emit "@ERROR|$req|invalid archive encoding"
                    return 0
                }
                arg="${arg%.tar.gz}"
                arg="${arg%.tar}"
                valid_archive_name "$arg" || {
                    emit "@ERROR|$req|invalid archive name"
                    return 0
                }
            fi
            ;;
        RECOVERY)
            [[ -z "$encoded_arg" ]] || {
                emit "@ERROR|$req|recovery does not accept an argument"
                return 0
            }
            ;;
        *)
            emit "@ERROR|$req|unsupported job domain"
            return 0
            ;;
    esac

    result="$("$JOBCTL" start "$domain" "$action" "${arg:--}" "$AUTH_USER" "$AUTH_ROLE" 2>&1)"
    status="${result%%|*}"

    if [[ "$status" != "STARTED" ]]; then
        emit "@ERROR|$req|job start failed: $result"
        return 0
    fi

    IFS='|' read -r _ jobid launcher <<< "$result"

    valid_job_id "$jobid" || {
        emit "@ERROR|$req|job controller returned invalid job id"
        return 0
    }

    audit "event=JOB_START user=\"$AUTH_USER\" role=$AUTH_ROLE job=$jobid domain=$domain action=$action launcher=$launcher arg=\"${arg:-daily}\""
    emit "@JOB|STARTED|$req|$jobid|$domain|$action|$launcher"
}

job_list()
{
    local line
    require_auth "-" || return 0
    [[ -x "$JOBCTL" ]] || {
        emit "@ERROR|-|job controller unavailable"
        return 0
    }

    emit "@JOBLIST|BEGIN"

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            JOB\|*)
                emit "@JOBITEM|${line#JOB|}"
                ;;
            COUNT\|*)
                emit "@JOBLIST|END|${line#COUNT|}"
                ;;
            *)
                ;;
        esac
    done < <("$JOBCTL" list 2>/dev/null)
}

job_status()
{
    local id="$1"
    local line

    require_auth "$id" || return 0
    valid_job_id "$id" || {
        emit "@ERROR|$id|invalid job id"
        return 0
    }

    line="$("$JOBCTL" status "$id" 2>/dev/null | head -n 1)"

    if [[ "$line" == JOB\|* ]]; then
        emit "@JOBSTATUS|${line#JOB|}"
    else
        emit "@ERROR|$id|job not found"
    fi
}

job_tail()
{
    local id="$1"
    local lines="${2:-120}"
    local line encoded

    require_auth "$id" || return 0
    valid_job_id "$id" || {
        emit "@ERROR|$id|invalid job id"
        return 0
    }

    [[ "$lines" =~ ^[0-9]+$ ]] || lines=120
    (( lines >= 1 )) || lines=1
    (( lines <= 500 )) || lines=500

    emit "@JOBLOG|BEGIN|$id"

    while IFS= read -r line || [[ -n "$line" ]]; do
        encoded="$(safe_b64_encode "$line")" || encoded=""
        emit "@JOBLOG|LINE|$id|$encoded"
    done < <("$JOBCTL" tail "$id" "$lines" 2>/dev/null)

    emit "@JOBLOG|END|$id"
}

job_cancel()
{
    local id="$1"
    local result

    require_auth "$id" || return 0
    valid_job_id "$id" || {
        emit "@ERROR|$id|invalid job id"
        return 0
    }

    result="$("$JOBCTL" cancel "$id" 2>&1)"

    if [[ "$result" == CANCEL_REQUESTED\|* ]]; then
        audit "event=JOB_CANCEL user=\"$AUTH_USER\" job=$id"
        emit "@JOB|CANCEL_REQUESTED|$id"
    else
        emit "@ERROR|$id|cancel failed: $result"
    fi
}

while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue

    if (( ${#line} > 8192 )); then
        emit "@ERROR|-|request too large"
        continue
    fi

    case "$line" in
        @AUTH\|*)
            IFS='|' read -r marker verb a1 a2 extra <<< "$line"
            [[ -z "${extra:-}" ]] || {
                emit "@AUTH|ERR|malformed authentication request"
                continue
            }
            handle_auth "${verb:-}" "${a1:-}" "${a2:-}"
            ;;

        @ACTION\|*)
            IFS='|' read -r marker req domain action extra <<< "$line"
            [[ -z "${extra:-}" ]] || {
                emit "@ERROR|-|malformed action request"
                continue
            }
            valid_request_id "$req" || {
                emit "@ERROR|-|invalid request id"
                continue
            }
            run_read_action "$req" "$domain" "$action"
            ;;

        @JOB\|START\|*)
            IFS='|' read -r marker verb req domain action arg extra <<< "$line"
            [[ -z "${extra:-}" ]] || {
                emit "@ERROR|-|malformed job start request"
                continue
            }
            valid_request_id "$req" || {
                emit "@ERROR|-|invalid request id"
                continue
            }
            job_start "$req" "$domain" "$action" "${arg:-}"
            ;;

        @JOB\|LIST)
            job_list
            ;;

        @JOB\|STATUS\|*)
            IFS='|' read -r marker verb id extra <<< "$line"
            [[ -z "${extra:-}" ]] || {
                emit "@ERROR|-|malformed job status request"
                continue
            }
            job_status "$id"
            ;;

        @JOB\|TAIL\|*)
            IFS='|' read -r marker verb id lines extra <<< "$line"
            [[ -z "${extra:-}" ]] || {
                emit "@ERROR|-|malformed job tail request"
                continue
            }
            job_tail "$id" "${lines:-120}"
            ;;

        @JOB\|CANCEL\|*)
            IFS='|' read -r marker verb id extra <<< "$line"
            [[ -z "${extra:-}" ]] || {
                emit "@ERROR|-|malformed job cancel request"
                continue
            }
            job_cancel "$id"
            ;;

        @VERSION)
            emit "@VERSION|wsmanager4.sh|$VERSION"
            ;;

        *)
            emit "@ERROR|-|unsupported protocol"
            ;;
    esac
done

exit 0
