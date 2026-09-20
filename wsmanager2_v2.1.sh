#!/usr/bin/env bash
# websocketd shared script manager v2.1
# Drop-in modernization of wsmanager2.sh:
#   - preserves the existing command -> script map
#   - removes eval and shell metacharacter interpretation
#   - routes pmsGP through pmsGP_web_v2.1.sh for server-side PMS auth
#   - preserves line-oriented response + EOF framing

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BASE_DIR="${WS_SCRIPT_DIR:-$(cd -- "$(dirname -- "$0")" && pwd)}"
MAX_LINE="${MAX_LINE:-8192}"
WS_ALLOW_EVAL="${WS_ALLOW_EVAL:-no}"

resolve_script() {
    case "$1" in
        eval)               [ "$WS_ALLOW_EVAL" = "yes" ] && printf '%s\n' 'eval_shell.sh' || return 1 ;;
        check_bonding)      printf '%s\n' 'check_bonding.sh' ;;
        check_ntp_time)     printf '%s\n' 'check_ntp_time.sh' ;;
        check_ping)         printf '%s\n' 'check_ping.sh' ;;
        read_asa_log)       printf '%s\n' 'read_asa_log.sh' ;;
        stop_asa_log)       printf '%s\n' 'stop_asa_log.sh' ;;
        read_asa_log_all)   printf '%s\n' 'read_asa_log_all.sh' ;;
        cb3100)             printf '%s\n' 'cb3100.sh' ;;
        cbah)               printf '%s\n' 'cbah.sh' ;;
        Nplus1)             printf '%s\n' 'Nplus1.sh' ;;
        Nplus1ah)           printf '%s\n' 'Nplus1ah.sh' ;;
        DR)                 printf '%s\n' 'DR.sh' ;;
        DRah)               printf '%s\n' 'DRah.sh' ;;
        flex)               printf '%s\n' 'flex.sh' ;;
        flexah)             printf '%s\n' 'flexah.sh' ;;
        clustat)            printf '%s\n' 'clustat.sh' ;;
        clustatah)          printf '%s\n' 'clustatah.sh' ;;
        server_poweron)     printf '%s\n' 'server_poweron.sh' ;;
        server_poweronah)   printf '%s\n' 'server_poweronah.sh' ;;
        server_poweroff)    printf '%s\n' 'server_poweroff.sh' ;;
        server_poweroffah)  printf '%s\n' 'server_poweroffah.sh' ;;
        copylog)            printf '%s\n' 'copylog.sh' ;;
        copylogah)          printf '%s\n' 'copylogah.sh' ;;
        coseXalertstop)     printf '%s\n' 'coseXalertstop.sh' ;;
        coseXalertstopah)   printf '%s\n' 'coseXalertstopah.sh' ;;
        kill)               printf '%s\n' 'kill.sh' ;;
        pmsGP)              printf '%s\n' 'pmsGP_web_v2.1.sh' ;;
        *)                  return 1 ;;
    esac
}

while IFS= read -r line; do
    if [ "${#line}" -gt "$MAX_LINE" ]; then
        printf '%s\n' 'ERROR|request too large' 'EOF'
        continue
    fi
    case "$line" in *$'\r'*|*$'\n'*) printf '%s\n' 'ERROR|invalid control character' 'EOF'; continue;; esac

    # This protocol is token based: fields may not contain spaces. Unlike the
    # legacy manager, metacharacters remain literal argv data and are never eval'd.
    read -r -a argv <<< "$line"
    if [ "${#argv[@]}" -eq 0 ]; then printf '%s\n' 'EOF'; continue; fi

    if [ "${argv[0]}" = "eval" ] && [ "$WS_ALLOW_EVAL" != "yes" ]; then
        printf '%s\n' 'ERROR|eval route disabled (set WS_ALLOW_EVAL=yes only if required)' 'EOF'
        continue
    fi

    if ! script=$(resolve_script "${argv[0]}"); then
        printf "I don't understand: %s\n" "${argv[0]}"
        printf '%s\n' 'EOF'
        continue
    fi

    path="$BASE_DIR/$script"
    if [ ! -x "$path" ]; then
        printf 'ERROR|script not executable: %s\n' "$script"
        printf '%s\n' 'EOF'
        continue
    fi

    # The old eval_shell route is retained for compatibility, but now receives
    # literal argv tokens. Consider disabling it after confirming no UI uses it.
    "$path" "${argv[@]:1}"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'ERROR|backend exit code %s\n' "$rc"
    fi
    printf '%s\n' 'EOF'
done

exit 0
