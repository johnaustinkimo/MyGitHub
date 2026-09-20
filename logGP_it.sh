#!/bin/bash

# logGP_it_v2.sh
# WebSocket backend helper for LogAnalyzer review UI.
# v2 adds a safe tg_https_proxy maintenance magic-command bridge.

umask 077

trap 'exit 0' SIGINT SIGTERM

TG_PROXY_CONF="${TG_PROXY_CONF:-/etc/tg_https_proxy.conf}"
# Send control traffic through Host B by default so the normal PROXY-protocol/
# maintenance_control_allow path is exercised. Override with an environment
# variable if this environment uses another frontend address.
TG_MAGIC_TARGET_HOST="${TG_MAGIC_TARGET_HOST:-192.168.167.68}"
TG_MAGIC_CONNECT_TIMEOUT="${TG_MAGIC_CONNECT_TIMEOUT:-5}"
TG_MAGIC_TOTAL_TIMEOUT="${TG_MAGIC_TOTAL_TIMEOUT:-10}"
TG_NC_BIN="${TG_NC_BIN:-$(command -v nc 2>/dev/null || true)}"
LOGGER_BIN="${LOGGER_BIN:-$(command -v logger 2>/dev/null || true)}"
BASE64_BIN="${BASE64_BIN:-$(command -v base64 2>/dev/null || true)}"
TIMEOUT_BIN="${TIMEOUT_BIN:-$(command -v timeout 2>/dev/null || true)}"

emit_magic_result() {
    local status="$1" port="$2" action="$3" text="$4" encoded=""
    if [[ -n "$BASE64_BIN" ]]; then
        encoded="$(printf '%s' "$text" | "$BASE64_BIN" -w 0 2>/dev/null)"
    fi
    if [[ -z "$encoded" && -n "$text" ]]; then
        # GNU base64 should exist on RHEL; keep protocol deterministic on failure.
        encoded="BASE64_UNAVAILABLE"
    fi
    printf 'MAGIC|%s|%s|%s|%s\n' "$status" "$port" "$action" "$encoded"
}

log_magic_audit() {
    [[ -z "$LOGGER_BIN" ]] && return 0
    "$LOGGER_BIN" -p daemon.info -t logGP_it -- "$*" 2>/dev/null || true
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Output: <port>|<label>. Returns non-zero if absent or duplicated.
lookup_port_mapping() {
    local requested_port="$1"
    [[ -r "$TG_PROXY_CONF" ]] || return 2

    awk -F'|' -v want="$requested_port" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            p=trim($1)
            if (p ~ /^[0-9]+$/ && p == want) {
                label=trim($4)
                count++
                found=p "|" label
            }
        }
        END {
            if (count == 1) { print found; exit 0 }
            if (count == 0) exit 3
            exit 4
        }
    ' "$TG_PROXY_CONF"
}

safe_b64_decode() {
    local encoded="$1" decoded
    [[ -n "$BASE64_BIN" ]] || return 1
    [[ ${#encoded} -le 4096 ]] || return 1
    decoded="$(printf '%s' "$encoded" | "$BASE64_BIN" -d 2>/dev/null)" || return 1
    # Magic command grammar is colon-delimited; block CR/LF/NUL-like controls and
    # colon in free text so user input cannot change the command structure.
    [[ ${#decoded} -le 512 ]] || return 1
    [[ "$decoded" != *$'\n'* && "$decoded" != *$'\r'* && "$decoded" != *:* ]] || return 1
    printf '%s' "$decoded"
}

build_magic_command() {
    local action="$1" arg1="${2:-}" arg2="${3:-}" text=""
    case "$action" in
        STATUS)
            printf '%s' '__TG_MAINTENANCE_STATUS__'
            ;;
        ON)
            printf '%s' '__TG_MAINTENANCE_ON__'
            ;;
        ON30M)
            printf '%s' '__TG_MAINTENANCE_ON_30M__'
            ;;
        ON_TTL)
            [[ "$arg1" =~ ^[0-9]+$ ]] || return 1
            (( 10#$arg1 >= 1 && 10#$arg1 <= 604800 )) || return 1
            if [[ -n "$arg2" && "$arg2" != "-" ]]; then
                text="$(safe_b64_decode "$arg2")" || return 1
                [[ -n "$text" ]] || return 1
                printf '__TG_MAINTENANCE_ON__:%s:%s' "$arg1" "$text"
            else
                printf '__TG_MAINTENANCE_ON__:%s' "$arg1"
            fi
            ;;
        EXTEND)
            [[ "$arg1" =~ ^[0-9]+$ ]] || return 1
            (( 10#$arg1 >= 1 && 10#$arg1 <= 604800 )) || return 1
            printf '__TG_MAINTENANCE_EXTEND__:%s' "$arg1"
            ;;
        OFF)
            printf '%s' '__TG_MAINTENANCE_OFF__'
            ;;
        MARK)
            text="$(safe_b64_decode "$arg1")" || return 1
            [[ -n "$text" ]] || return 1
            printf '__TG_MAINTENANCE_MARK__:%s' "$text"
            ;;
        TEST)
            text="$(safe_b64_decode "$arg1")" || return 1
            [[ -n "$text" ]] || return 1
            printf '__TG_TEST_LOG_ONLY__:%s' "$text"
            ;;
        *)
            return 1
            ;;
    esac
}

run_magic_command() {
    local port="${2:-}" action="${3:-}" arg1="${4:-}" arg2="${5:-}"
    local mapping label magic response rc

    action="${action^^}"

    if ! valid_port "$port"; then
        emit_magic_result "ERR" "$port" "$action" "invalid port"
        return 0
    fi

    mapping="$(lookup_port_mapping "$port")"
    rc=$?
    case "$rc" in
        0) ;;
        2) emit_magic_result "ERR" "$port" "$action" "cannot read $TG_PROXY_CONF"; return 0 ;;
        3) emit_magic_result "ERR" "$port" "$action" "port is not mapped in $TG_PROXY_CONF"; return 0 ;;
        4) emit_magic_result "ERR" "$port" "$action" "duplicate port mapping in $TG_PROXY_CONF"; return 0 ;;
        *) emit_magic_result "ERR" "$port" "$action" "port mapping lookup failed"; return 0 ;;
    esac
    label="${mapping#*|}"

    magic="$(build_magic_command "$action" "$arg1" "$arg2")" || {
        emit_magic_result "ERR" "$port" "$action" "invalid magic command arguments"
        return 0
    }

    if [[ -z "$TG_NC_BIN" || -z "$TIMEOUT_BIN" ]]; then
        emit_magic_result "ERR" "$port" "$action" "nc or timeout command not found"
        return 0
    fi

    log_magic_audit "event=MAGIC_COMMAND_REQUEST port=$port label=\"$label\" action=$action target=$TG_MAGIC_TARGET_HOST"

    # tg_https_proxy terminates the connection after returning the magic result.
    # -w limits network idle; timeout is a second hard upper bound.
    response="$(printf '%s\n' "$magic" | "$TIMEOUT_BIN" "${TG_MAGIC_TOTAL_TIMEOUT}s" "$TG_NC_BIN" -w "$TG_MAGIC_CONNECT_TIMEOUT" "$TG_MAGIC_TARGET_HOST" "$port" 2>&1)"
    rc=$?

    if (( rc != 0 )); then
        log_magic_audit "event=MAGIC_COMMAND_RESULT port=$port label=\"$label\" action=$action result=error rc=$rc"
        emit_magic_result "ERR" "$port" "$action" "backend connection failed (rc=$rc): $response"
        return 0
    fi

    if [[ "$response" == OK\ * ]]; then
        log_magic_audit "event=MAGIC_COMMAND_RESULT port=$port label=\"$label\" action=$action result=ok"
        emit_magic_result "OK" "$port" "$action" "$response"
    elif [[ "$response" == ERROR\ * ]]; then
        log_magic_audit "event=MAGIC_COMMAND_RESULT port=$port label=\"$label\" action=$action result=denied_or_error"
        emit_magic_result "ERR" "$port" "$action" "$response"
    else
        log_magic_audit "event=MAGIC_COMMAND_RESULT port=$port label=\"$label\" action=$action result=unexpected"
        emit_magic_result "ERR" "$port" "$action" "unexpected backend response: $response"
    fi
}

if [[ "${1:-}" == "magic_command" ]]; then
    run_magic_command "$@"
    exit 0
fi

if [[ "${1:-}" == "loginQuery" ]] ; then
    login_username="${2:-}"
    login_password="${3:-}"
    ad_url="ldaps://192.168.169.130"
    ad1_addr="192.168.169.130"
    ad2_addr="192.168.169.131"
    ldap_port="636"
    ldap_proto="ldaps"
    LDAPSEARCH="$(command -v ldapsearch 2>/dev/null || true)"
    icount=0
    NETCAT="$(command -v nc 2>/dev/null || true)"

    if [[ -z "$LDAPSEARCH" || -z "$NETCAT" ]]; then
        echo "0|USER"
        exit 0
    fi

    "$NETCAT" -vz "$ad1_addr" "$ldap_port" &>/dev/null
    if [[ "$?" -eq 0 ]] ; then
        ad_url="$ldap_proto://$ad1_addr"
        ((icount++))
    fi
    if [[ "$icount" -eq 0 ]]; then
        "$NETCAT" -vz "$ad2_addr" "$ldap_port" &>/dev/null
        if [[ "$?" -eq 0 ]] ; then
            ad_url="$ldap_proto://$ad2_addr"
        else
            echo "0|USER"
            exit 0
        fi
    fi

    # Preserve the two existing local fallback accounts for compatibility.
    # Recommendation: move these credentials to a root-readable file or remove
    # them once AD-only authentication is accepted operationally.
    if [[ "$login_username" == "admin" ]] && [[ "$login_password" == "intL@9pw" ]] ; then
        echo "1|ADMIN"; exit 0
    fi

    if [[ "$login_username" == "onboard" ]] && [[ "$login_password" == "Taifex@1234" ]] ; then
        echo "1|USER"; exit 0
    fi

    "$LDAPSEARCH" -H "$ad_url" -x -D "$login_username@taifex.com.tw" -w "$login_password" \
        -b "dc=taifex,dc=com,dc=tw" "(sAMAccountName=$login_username)" &>/dev/null

    if [[ "$?" -eq 0 ]] ; then
        echo "1|USER"; exit 0
    else
        echo "0|USER"; exit 0
    fi
fi

exit 0
