#!/usr/bin/env bash
#
# hicloud_jobctl_v1.0.1.sh
#
# v1.0.1
# - Force deterministic JOB_WORKING_DIR for systemd-run and setsid workers.
# - Preserve failed transient units for troubleshooting.
# - Record systemd ActiveState/SubState/Result/ExecMainStatus.
# - Record failure_reason in job state.
#

set -uo pipefail
umask 077

VERSION="1.0.1"
CONFIG_FILE="${HICLOUD_JOBCTL_CONFIG:-/etc/hicloud-jobctl.conf}"

if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

: "${UPLOAD_SCRIPT:=/ws/hicloud_latest_upload.sh}"
: "${RECOVERY_SCRIPT:=/ws/hicloud_latest_recovery.sh}"
: "${JOB_STATE_DIR:=/var/lib/hicloud-web-jobs}"
: "${JOB_LOG_DIR:=/var/log/hicloud-web-jobs}"
: "${JOB_WORKING_DIR:=/ws/linux/usr/bin}"
: "${USE_SYSTEMD_RUN:=yes}"
: "${JOB_RETENTION_DAYS:=30}"
: "${START_GRACE_SEC:=15}"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

mkdir -p "$JOB_STATE_DIR" "$JOB_LOG_DIR" || {
    echo "ERROR|cannot create job directories"
    exit 1
}

chmod 700 "$JOB_STATE_DIR" "$JOB_LOG_DIR" 2>/dev/null || true

[[ -d "$JOB_WORKING_DIR" ]] || {
    echo "ERROR|JOB_WORKING_DIR does not exist: $JOB_WORKING_DIR"
    exit 1
}

is_yes()
{
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

valid_job_id()
{
    [[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+-[A-Fa-f0-9]{6}$ ]]
}

valid_archive_name()
{
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

valid_identity()
{
    [[ "${1:-}" =~ ^[A-Za-z0-9._@-]{1,128}$ ]]
}

job_dir()
{
    printf '%s/%s\n' "$JOB_STATE_DIR" "$1"
}

job_log()
{
    printf '%s/%s.log\n' "$JOB_LOG_DIR" "$1"
}

write_field()
{
    local dir="$1" name="$2" value="${3:-}"
    printf '%s\n' "$value" > "${dir}/${name}.tmp" &&
        mv -f "${dir}/${name}.tmp" "${dir}/${name}"
    chmod 600 "${dir}/${name}" 2>/dev/null || true
}

read_field()
{
    local dir="$1" name="$2"
    [[ -r "${dir}/${name}" ]] &&
        head -n 1 "${dir}/${name}" 2>/dev/null
}

now_iso()
{
    date '+%Y-%m-%d %H:%M:%S %z'
}

new_job_id()
{
    local rand
    rand="$(printf '%06x' "$(( (RANDOM << 1) ^ RANDOM ^ $$ ))")"
    printf '%s-%s-%s-%s\n' \
        "$(date '+%Y%m%d')" \
        "$(date '+%H%M%S')" \
        "$$" \
        "$rand"
}

refresh_one()
{
    local id="$1"
    local dir state launcher unit pid created now age
    local active sub result exec_status

    valid_job_id "$id" || return 1

    dir="$(job_dir "$id")"
    [[ -d "$dir" ]] || return 1

    state="$(read_field "$dir" state)"

    case "$state" in
        PENDING|RUNNING) ;;
        *) return 0 ;;
    esac

    launcher="$(read_field "$dir" launcher)"

    if [[ "$launcher" == "systemd" ]]; then

        unit="$(read_field "$dir" unit)"
        [[ -n "$unit" ]] || return 0

        active="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
        sub="$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)"
        result="$(systemctl show "$unit" -p Result --value 2>/dev/null || true)"
        exec_status="$(systemctl show "$unit" -p ExecMainStatus --value 2>/dev/null || true)"

        write_field "$dir" systemd_active_state "${active:-unknown}"
        write_field "$dir" systemd_sub_state "${sub:-unknown}"
        write_field "$dir" systemd_result "${result:-unknown}"
        write_field "$dir" systemd_exec_status "${exec_status:-unknown}"

        case "$active" in
            active|activating|reloading|deactivating)
                return 0
                ;;
        esac

        state="$(read_field "$dir" state)"

        case "$state" in
            SUCCESS|FAILED|CANCELLED|INTERRUPTED)
                return 0
                ;;
        esac

        created="$(read_field "$dir" created_epoch)"
        now="$(date +%s)"

        if [[ "$created" =~ ^[0-9]+$ ]]; then
            age=$((now - created))
        else
            age="$START_GRACE_SEC"
        fi

        (( age >= START_GRACE_SEC )) || return 0

        if [[ "$active" == "failed" ||
              "$result" == "exit-code" ||
              "$result" == "signal" ||
              "$result" == "timeout" ]]; then

            write_field "$dir" state "FAILED"

            if [[ "$exec_status" =~ ^[0-9]+$ ]]; then
                write_field "$dir" rc "$exec_status"
            else
                write_field "$dir" rc "255"
            fi

            write_field "$dir" failure_reason \
                "systemd: Active=${active:-unknown} Sub=${sub:-unknown} Result=${result:-unknown} ExecMainStatus=${exec_status:-unknown}"

        else

            write_field "$dir" state "INTERRUPTED"
            write_field "$dir" rc "255"
            write_field "$dir" failure_reason \
                "worker ended without final state: Active=${active:-unknown} Sub=${sub:-unknown} Result=${result:-unknown}"
        fi

        write_field "$dir" ended_at "$(now_iso)"
        write_field "$dir" ended_epoch "$(date +%s)"

        return 0
    fi

    if [[ "$launcher" == "setsid" ]]; then

        pid="$(read_field "$dir" pid)"

        if [[ "$pid" =~ ^[0-9]+$ ]] &&
           kill -0 "$pid" 2>/dev/null; then
            return 0
        fi

        state="$(read_field "$dir" state)"

        case "$state" in
            SUCCESS|FAILED|CANCELLED|INTERRUPTED)
                return 0
                ;;
        esac

        created="$(read_field "$dir" created_epoch)"
        now="$(date +%s)"

        if [[ "$created" =~ ^[0-9]+$ ]] &&
           (( now - created < START_GRACE_SEC )); then
            return 0
        fi

        write_field "$dir" state "INTERRUPTED"
        write_field "$dir" rc "255"
        write_field "$dir" failure_reason \
            "setsid worker disappeared before final state"
        write_field "$dir" ended_at "$(now_iso)"
        write_field "$dir" ended_epoch "$(date +%s)"
    fi
}

start_job()
{
    local domain="${1^^}"
    local action="${2^^}"
    local arg="${3:-}"
    local user="${4:-unknown}"
    local role="${5:-USER}"

    local id dir log unit launcher pid rc

    [[ "$action" == "RUN" ]] || {
        echo "ERROR|unsupported action"
        return 2
    }

    case "$domain" in
        UPLOAD)
            [[ -x "$UPLOAD_SCRIPT" ]] || {
                echo "ERROR|upload script not executable: $UPLOAD_SCRIPT"
                return 1
            }

            if [[ -n "$arg" && "$arg" != "-" ]]; then
                arg="${arg%.tar.gz}"
                arg="${arg%.tar}"
                valid_archive_name "$arg" || {
                    echo "ERROR|invalid archive name"
                    return 2
                }
            else
                arg=""
            fi
            ;;

        RECOVERY)
            [[ -x "$RECOVERY_SCRIPT" ]] || {
                echo "ERROR|recovery script not executable: $RECOVERY_SCRIPT"
                return 1
            }
            [[ -z "$arg" || "$arg" == "-" ]] || {
                echo "ERROR|recovery RUN does not accept argument"
                return 2
            }
            arg=""
            ;;

        *)
            echo "ERROR|unsupported domain"
            return 2
            ;;
    esac

    valid_identity "$user" || user="unknown"
    valid_identity "$role" || role="USER"

    id="$(new_job_id)"
    dir="$(job_dir "$id")"
    log="$(job_log "$id")"

    mkdir -m 700 "$dir" || {
        echo "ERROR|cannot create job directory"
        return 1
    }

    : > "$log"
    chmod 600 "$log"

    write_field "$dir" id "$id"
    write_field "$dir" state "PENDING"
    write_field "$dir" domain "$domain"
    write_field "$dir" action "$action"
    write_field "$dir" arg "$arg"
    write_field "$dir" user "$user"
    write_field "$dir" role "$role"
    write_field "$dir" created_at "$(now_iso)"
    write_field "$dir" created_epoch "$(date +%s)"
    write_field "$dir" rc "-"
    write_field "$dir" launcher ""
    write_field "$dir" unit ""
    write_field "$dir" pid ""
    write_field "$dir" failure_reason ""
    write_field "$dir" working_dir "$JOB_WORKING_DIR"

    {
        echo "================================================================"
        echo "[BOOTSTRAP] job=$id"
        echo "[BOOTSTRAP] version=$VERSION"
        echo "[BOOTSTRAP] domain=$domain action=$action"
        echo "[BOOTSTRAP] requested_by=$user role=$role"
        echo "[BOOTSTRAP] working_dir=$JOB_WORKING_DIR"
        echo "[BOOTSTRAP] jobctl=$SELF"
        echo "[BOOTSTRAP] created=$(now_iso)"
        echo "================================================================"
    } >> "$log"

    launcher=""

    if is_yes "$USE_SYSTEMD_RUN" &&
       command -v systemd-run >/dev/null 2>&1 &&
       command -v systemctl >/dev/null 2>&1; then

        unit="hicloud-job-${id}.service"

        write_field "$dir" launcher "systemd"
        write_field "$dir" unit "$unit"

        systemd-run \
            --quiet \
            --unit="$unit" \
            --working-directory="$JOB_WORKING_DIR" \
            --property=Type=simple \
            --property=Nice=5 \
            --property=KillMode=control-group \
            --property=TimeoutStartSec=0 \
            /usr/bin/env \
                HICLOUD_JOBCTL_CONFIG="$CONFIG_FILE" \
                "$SELF" worker "$id" \
            >/dev/null 2>&1

        rc=$?

        if (( rc == 0 )); then
            launcher="systemd"
        else
            echo "[BOOTSTRAP] systemd-run failed rc=$rc; fallback to setsid" >> "$log"
            write_field "$dir" launcher ""
            write_field "$dir" unit ""
        fi
    fi

    if [[ -z "$launcher" ]]; then

        command -v setsid >/dev/null 2>&1 || {
            write_field "$dir" state "FAILED"
            write_field "$dir" rc "127"
            write_field "$dir" failure_reason "setsid not available"
            write_field "$dir" ended_at "$(now_iso)"
            echo "ERROR|no detached launcher available"
            return 1
        }

        write_field "$dir" launcher "setsid"

        nohup setsid bash -c '
            cd "$1" || exit 111
            shift
            exec "$@"
        ' _ \
            "$JOB_WORKING_DIR" \
            /usr/bin/env \
            HICLOUD_JOBCTL_CONFIG="$CONFIG_FILE" \
            "$SELF" worker "$id" \
            </dev/null \
            >>"$log" 2>&1 &

        pid=$!

        launcher="setsid"

        write_field "$dir" pid "$pid"
    fi

    printf 'STARTED|%s|%s\n' "$id" "$launcher"
}

worker_cancelled()
{
    local id="$1"
    local dir

    dir="$(job_dir "$id")"

    echo
    echo "[JOB] CANCELLED at $(now_iso)"

    write_field "$dir" state "CANCELLED"
    write_field "$dir" rc "143"
    write_field "$dir" failure_reason "cancelled by operator"
    write_field "$dir" ended_at "$(now_iso)"
    write_field "$dir" ended_epoch "$(date +%s)"

    exit 143
}

worker()
{
    local id="$1"
    local dir log
    local domain action arg user role
    local rc=1

    valid_job_id "$id" || exit 2

    dir="$(job_dir "$id")"
    log="$(job_log "$id")"

    [[ -d "$dir" ]] || exit 2

    exec >>"$log" 2>&1

    trap 'worker_cancelled "$id"' TERM INT HUP

    echo "[WORKER] pid=$$"
    echo "[WORKER] pwd=$(pwd -P)"
    echo "[WORKER] HOME=${HOME:-<unset>}"
    echo "[WORKER] PATH=$PATH"
    echo "[WORKER] started=$(now_iso)"

    if [[ "$(pwd -P)" != "$JOB_WORKING_DIR" ]]; then
        echo "[WORKER] changing cwd to $JOB_WORKING_DIR"
        cd "$JOB_WORKING_DIR" || {
            write_field "$dir" state "FAILED"
            write_field "$dir" rc "111"
            write_field "$dir" failure_reason \
                "cannot cd to JOB_WORKING_DIR=$JOB_WORKING_DIR"
            write_field "$dir" ended_at "$(now_iso)"
            exit 111
        }
    fi

    echo "[WORKER] effective_pwd=$(pwd -P)"

    domain="$(read_field "$dir" domain)"
    action="$(read_field "$dir" action)"
    arg="$(read_field "$dir" arg)"
    user="$(read_field "$dir" user)"
    role="$(read_field "$dir" role)"

    write_field "$dir" state "RUNNING"
    write_field "$dir" started_at "$(now_iso)"
    write_field "$dir" started_epoch "$(date +%s)"
    write_field "$dir" worker_pid "$$"

    echo "================================================================"
    echo "[JOB] HiCloud detached operation"
    echo "[JOB] id=$id"
    echo "[JOB] domain=$domain action=$action"
    echo "[JOB] requested_by=$user role=$role"
    echo "[JOB] argument=${arg:-daily/default}"
    echo "[JOB] working_dir=$(pwd -P)"
    echo "[JOB] started=$(now_iso)"
    echo "================================================================"
    echo

    case "$domain:$action" in

        UPLOAD:RUN)
            if [[ -n "$arg" ]]; then
                "$UPLOAD_SCRIPT" run "$arg"
                rc=$?
            else
                "$UPLOAD_SCRIPT" run
                rc=$?
            fi
            ;;

        RECOVERY:RUN)
            "$RECOVERY_SCRIPT" run
            rc=$?
            ;;

        *)
            echo "[JOB] unsupported operation: $domain:$action"
            rc=2
            ;;
    esac

    echo
    echo "================================================================"
    echo "[JOB] command exit rc=$rc"
    echo "[JOB] ended=$(now_iso)"
    echo "================================================================"

    write_field "$dir" rc "$rc"
    write_field "$dir" ended_at "$(now_iso)"
    write_field "$dir" ended_epoch "$(date +%s)"

    if (( rc == 0 )); then
        write_field "$dir" state "SUCCESS"
        write_field "$dir" failure_reason ""
    else
        write_field "$dir" state "FAILED"
        write_field "$dir" failure_reason "backend script exited rc=$rc"
    fi

    exit "$rc"
}

emit_job()
{
    local id="$1"
    local dir
    local state domain action arg user role
    local created started ended rc launcher reason workdir

    refresh_one "$id" || true

    dir="$(job_dir "$id")"

    state="$(read_field "$dir" state)"
    domain="$(read_field "$dir" domain)"
    action="$(read_field "$dir" action)"
    arg="$(read_field "$dir" arg)"
    user="$(read_field "$dir" user)"
    role="$(read_field "$dir" role)"
    created="$(read_field "$dir" created_at)"
    started="$(read_field "$dir" started_at)"
    ended="$(read_field "$dir" ended_at)"
    rc="$(read_field "$dir" rc)"
    launcher="$(read_field "$dir" launcher)"
    reason="$(read_field "$dir" failure_reason)"
    workdir="$(read_field "$dir" working_dir)"

    reason="${reason//|//}"
    workdir="${workdir//|//}"

    printf 'JOB|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$id" \
        "${state:--}" \
        "${domain:--}" \
        "${action:--}" \
        "${arg:--}" \
        "${user:--}" \
        "${role:--}" \
        "${created:--}" \
        "${started:--}" \
        "${ended:--}" \
        "${rc:--}" \
        "${launcher:--}" \
        "${reason:--}" \
        "${workdir:--}"
}

list_jobs()
{
    local dir id count=0

    while IFS= read -r dir; do

        [[ -n "$dir" ]] || continue

        id="${dir##*/}"

        valid_job_id "$id" || continue

        emit_job "$id"

        count=$((count + 1))

    done < <(
        find "$JOB_STATE_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -print 2>/dev/null |
        LC_ALL=C sort -r
    )

    printf 'COUNT|%d\n' "$count"
}

status_job()
{
    local id="$1"

    valid_job_id "$id" || {
        echo "ERROR|invalid job id"
        return 2
    }

    [[ -d "$(job_dir "$id")" ]] || {
        echo "ERROR|job not found"
        return 3
    }

    emit_job "$id"
}

tail_job()
{
    local id="$1"
    local lines="${2:-100}"
    local log

    valid_job_id "$id" || return 2

    [[ "$lines" =~ ^[0-9]+$ ]] || lines=100

    (( lines >= 1 )) || lines=1
    (( lines <= 500 )) || lines=500

    log="$(job_log "$id")"

    [[ -r "$log" ]] || return 0

    tail -n "$lines" -- "$log"
}

cancel_job()
{
    local id="$1"
    local dir state launcher unit pid worker_pid

    valid_job_id "$id" || {
        echo "ERROR|invalid job id"
        return 2
    }

    dir="$(job_dir "$id")"

    [[ -d "$dir" ]] || {
        echo "ERROR|job not found"
        return 3
    }

    refresh_one "$id" || true

    state="$(read_field "$dir" state)"

    case "$state" in
        PENDING|RUNNING) ;;
        *)
            echo "ERROR|job is not running"
            return 4
            ;;
    esac

    launcher="$(read_field "$dir" launcher)"

    if [[ "$launcher" == "systemd" ]]; then

        unit="$(read_field "$dir" unit)"

        [[ -n "$unit" ]] || {
            echo "ERROR|missing systemd unit"
            return 5
        }

        systemctl stop "$unit" >/dev/null 2>&1 || true

    elif [[ "$launcher" == "setsid" ]]; then

        worker_pid="$(read_field "$dir" worker_pid)"
        pid="$(read_field "$dir" pid)"

        if [[ "$worker_pid" =~ ^[0-9]+$ ]]; then
            kill -TERM -- "-$worker_pid" 2>/dev/null ||
                kill -TERM "$worker_pid" 2>/dev/null || true
        elif [[ "$pid" =~ ^[0-9]+$ ]]; then
            kill -TERM -- "-$pid" 2>/dev/null ||
                kill -TERM "$pid" 2>/dev/null || true
        fi
    else
        echo "ERROR|unknown launcher"
        return 5
    fi

    echo "CANCEL_REQUESTED|$id"
}

case "${1:-}" in
    start)
        shift
        start_job "$@"
        ;;
    worker)
        worker "${2:-}"
        ;;
    list)
        list_jobs
        ;;
    status)
        status_job "${2:-}"
        ;;
    tail)
        tail_job "${2:-}" "${3:-100}"
        ;;
    cancel)
        cancel_job "${2:-}"
        ;;
    version|--version|-V)
        echo "hicloud_jobctl_v1.0.1.sh v${VERSION}"
        ;;
    *)
        cat <<EOF
HiCloud Job Controller v${VERSION}

Usage:
  $0 start UPLOAD RUN [archive|-] <user> <role>
  $0 start RECOVERY RUN - <user> <role>
  $0 list
  $0 status <job_id>
  $0 tail <job_id> [1-500]
  $0 cancel <job_id>
  $0 version
EOF
        exit 2
        ;;
esac
