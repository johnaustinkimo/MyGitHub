#!/usr/bin/env bash
# PMS Web safety wrapper v2.1
# Keeps the existing /ws/pmsGP.sh business logic, but moves the security
# boundary to the server side for WebSocket clients.
#
# Security properties:
#   - exact account/password match against gen_file (no regex password match)
#   - derives role from gen_file and ignores a forged client iType
#   - enforces password expiry server-side
#   - non-admin users may only query their vault or change their own Web password
#   - allowlisted modes and mode-specific input validation
#   - shared/exclusive flock across concurrent websocketd clients
#   - no eval

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PMS_CORE="${PMS_CORE:-/ws/pmsGP_v2.1.sh}"
GEN_FILE="${GEN_FILE:-/ws/gen_file}"
GES_FILE="${GES_FILE:-/ws/ges_file}"
LOG_FILE="${LOG_FILE:-/ws/log_file}"
LOCK_FILE="${PMS_LOCK_FILE:-/run/lock/pms_web.lock}"

[ "$#" -eq 8 ] || { echo "ERROR|expected 8 arguments"; exit 64; }
[ -x "$PMS_CORE" ] || { echo "ERROR|pms core not executable"; exit 69; }
[ -r "$GEN_FILE" ] || { echo "ERROR|gen_file not readable"; exit 69; }

client_type=$1
imode=$2
iuser=$3
ipwd=$4
p1=$5
p2=$6
p3=$7
p4=$8

case "$imode" in
    loginQuery|statusQuery|pmsQuery|usersQuery|logQuery|pms2Query|gemQuery|genQuery|geoQuery|gepQuery|pexQuery|reloadQuery|gemSave|genSave|geoSave|gepSave|gerSave|gesSave|getSave|geuSave|pmsSave|pms2Save)
        ;;
    *) echo "ERROR|unsupported mode"; exit 65 ;;
esac

# The direct argv execution path makes ordinary punctuation safe, but these
# controls are never valid PMS field data and are rejected early.
reject_control() {
    local name=$1 value=$2
    case "$value" in
        *$'\n'*|*$'\r'*|*$'\t'*|*';'*|*'`'*|*'$('*|*'${'*|*'<'*|*'>'*|*'\\'*)
            echo "ERROR|unsafe characters in $name"
            exit 65
            ;;
    esac
    case "$value" in *' '*) echo "ERROR|spaces are not supported in $name"; exit 65;; esac
}

reject_control iuser "$iuser"
reject_control ipwd "$ipwd"
reject_control p1 "$p1"
reject_control p2 "$p2"
reject_control p3 "$p3"
reject_control p4 "$p4"

case "$iuser" in *'|'*) echo "ERROR|invalid user"; exit 65;; esac
case "$ipwd" in *'|'*) echo "ERROR|invalid password"; exit 65;; esac

lookup_identity() {
    awk -F'|' -v u="$iuser" -v p="$ipwd" '
        $1 == u && $2 == p && $4 == "Y" { print $3 "|" $5; exit }
    ' "$GEN_FILE"
}

is_expired() {
    local updated=$1 days now_epoch old_epoch
    days=$(awk -F'|' 'NR==1 {print $1; exit}' "$GES_FILE" 2>/dev/null)
    case "$days" in ''|*[!0-9]*) days=90;; esac
    updated=${updated%%_*}
    old_epoch=$(date -d "$updated" +%s 2>/dev/null) || return 0
    now_epoch=$(date +%s)
    [ $(( (now_epoch - old_epoch) / 86400 )) -gt "$days" ]
}

log_login() {
    local result=$1
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s|loginQuery|USER|%s|%s\n' "$iuser" "$result" "$(date +'%Y/%m/%d %T')" >> "$LOG_FILE" 2>/dev/null || true
}

identity=$(lookup_identity)
if [ -z "$identity" ]; then
    if [ "$imode" = "loginQuery" ]; then
        log_login "[Failed] loginID: [$iuser] Check LoginID Password Profile Failed"
        echo "0|USER"
        exit 0
    fi
    echo "ERROR|AUTH_FAILED"
    exit 77
fi

actual_role=${identity%%|*}
updated_at=${identity#*|}
case "$actual_role" in
    ADMIN|ADMINA|ADMINB|GOD) effective_type=ADMIN; is_admin=1 ;;
    *) effective_type=USER; is_admin=0 ;;
esac

expired=0
if is_expired "$updated_at"; then expired=1; fi

if [ "$imode" = "loginQuery" ]; then
    if [ "$expired" -eq 1 ]; then
        log_login "[Failed] loginID: [$iuser] Password Expired"
        echo "-1|EXP|$actual_role"
    else
        log_login "[OK] loginID: [$iuser] Check LoginID Password Profile OK"
        echo "1|$actual_role"
    fi
    exit 0
fi

# Expired accounts can only change their own Web login password.
if [ "$expired" -eq 1 ] && [ "$imode" != "genSave" ]; then
    echo "ERROR|PASSWORD_EXPIRED"
    exit 77
fi

# For an expired identity, self-service password reset must preserve the
# server-side role/status. This also fixes the legacy UI behavior that could
# accidentally turn an expired ADMIN record into USER.
if [ "$expired" -eq 1 ] && [ "$imode" = "genSave" ] && [ "$p1" = "$iuser" ]; then
    p3="$actual_role"
    p4="Y"
fi

# Browser-facing authorization policy. Do not trust client_type.
if [ "$is_admin" -eq 0 ]; then
    case "$imode" in
        pmsQuery|statusQuery)
            ;;
        genSave)
            [ "$p1" = "$iuser" ] || { echo "ERROR|FORBIDDEN"; exit 77; }
            # Prevent self-service privilege escalation / disabling the account.
            p3="$actual_role"
            p4="Y"
            ;;
        *)
            echo "ERROR|FORBIDDEN"
            exit 77
            ;;
    esac
fi

# Mode-specific validation for write operations. The legacy core builds sed,
# grep and cron expressions internally, so constrain values before delegation.
case "$imode" in
    genSave)
        printf '%s' "$p1" | grep -Eq '^[A-Za-z0-9_.-]{1,64}$' || { echo "ERROR|invalid login id"; exit 65; }
        printf '%s' "$p2" | grep -Eq '^[A-Za-z0-9@._%+=:!#^-]{5,128}$' || { echo "ERROR|new password contains unsupported characters"; exit 65; }
        case "$p3" in USER|ADMIN|ADMINA|ADMINB|GOD) ;; *) echo "ERROR|invalid role"; exit 65;; esac
        case "$p4" in Y|N) ;; *) echo "ERROR|invalid status"; exit 65;; esac
        ;;
    gemSave)
        printf '%s' "$p1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "ERROR|invalid ip"; exit 65; }
        printf '%s' "$p2" | grep -Eq '^[A-Za-z0-9_.-]{1,128}$' || { echo "ERROR|invalid hostname"; exit 65; }
        case "$p3" in Linux|AIX|SunOS) ;; *) echo "ERROR|invalid os"; exit 65;; esac
        case "$p4" in Y|N) ;; *) echo "ERROR|invalid status"; exit 65;; esac
        ;;
    geoSave)
        printf '%s' "$p1" | grep -Eq '^[A-Za-z0-9_.-]{1,64}$' || { echo "ERROR|invalid os account"; exit 65; }
        printf '%s' "$p2" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$' || { echo "ERROR|invalid description"; exit 65; }
        case "$p3" in Y|N) ;; *) echo "ERROR|invalid status"; exit 65;; esac
        ;;
    gepSave)
        printf '%s' "$p1" | grep -Eq '^([A-Za-z0-9_.-]+\|[A-Za-z0-9_.-]+@[YN])(,([A-Za-z0-9_.-]+\|[A-Za-z0-9_.-]+@[YN]))*$' || { echo "ERROR|invalid authorization payload"; exit 65; }
        printf '%s' "$p2" | grep -Eq '^[A-Za-z0-9_.-]+@$' || { echo "ERROR|invalid authorization user"; exit 65; }
        ;;
    gerSave)
        printf '%s' "$p1" | grep -Eq '^[0-9]{1,2}$' || { echo "ERROR|invalid password length"; exit 65; }
        [ "$p1" -ge 8 ] && [ "$p1" -le 64 ] || { echo "ERROR|password length out of range"; exit 65; }
        ;;
    gesSave)
        printf '%s' "$p1" | grep -Eq '^[0-9]{1,4}$' || { echo "ERROR|invalid expiry"; exit 65; }
        [ "$p1" -ge 1 ] && [ "$p1" -le 3650 ] || { echo "ERROR|expiry out of range"; exit 65; }
        ;;
    getSave)
        printf '%s' "$p1" | grep -Eq '^(all|[A-Za-z0-9_.-]+(\|[A-Za-z0-9_.-]+)*)$' || { echo "ERROR|invalid rotation account list"; exit 65; }
        printf '%s' "$p2" | grep -Eq '^[0-9]{1,2}$' || { echo "ERROR|invalid minute"; exit 65; }
        printf '%s' "$p3" | grep -Eq '^[0-9]{1,2}$' || { echo "ERROR|invalid hour"; exit 65; }
        [ "$p2" -ge 0 ] && [ "$p2" -le 59 ] || { echo "ERROR|minute out of range"; exit 65; }
        [ "$p3" -ge 0 ] && [ "$p3" -le 23 ] || { echo "ERROR|hour out of range"; exit 65; }
        case "$p4" in DAILY|WEEKLY|MONTHLY|HOURLY) ;; *) echo "ERROR|invalid frequency"; exit 65;; esac
        ;;
    geuSave)
        printf '%s' "$p1" | grep -Eq '^[A-Za-z0-9@._%+=:!#^-]{8,128}$' || { echo "ERROR|invalid encryption seed"; exit 65; }
        ;;
    pmsSave|pms2Save)
        printf '%s' "$p1" | grep -Eq '^(all|[A-Za-z0-9_.-]+(\|[A-Za-z0-9_.-]+)*)$' || { echo "ERROR|invalid rotation account list"; exit 65; }
        ;;
esac

write_mode=0
case "$imode" in gemSave|genSave|geoSave|gepSave|gerSave|gesSave|getSave|geuSave|pmsSave|pms2Save) write_mode=1;; esac

mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 9>"$LOCK_FILE" || { echo "ERROR|cannot open lock file"; exit 73; }
if [ "$write_mode" -eq 1 ]; then
    flock -x -w 30 9 || { echo "ERROR|another PMS write is still running"; exit 75; }
else
    flock -s -w 30 9 || { echo "ERROR|PMS is busy"; exit 75; }
fi

# Effective server-derived role is passed to the legacy core. client_type is
# intentionally ignored after parsing.
"$PMS_CORE" "$effective_type" "$imode" "$iuser" "$ipwd" "$p1" "$p2" "$p3" "$p4"
exit $?
