#!/usr/bin/env bash

#exit 0 ;

# set -euo pipefail
# IFS=$'\n\t'
# trap 'log_err "Unexpected failure at line $LINENO"; exit 1' ERR

# ===============================
# ENVIRONMENT
# ===============================
PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH

. /sybase/SYBASE.sh &>/dev/null

# ===============================
# CONFIGURATION
# ===============================
DHOST="taifex-bk"
OPNO="${1:-Z0666}"
JobID="${OPNO}"

# Remote host
HOST="taifex-bk"
REMOTE_USER="${REMOTE_USER:-root}"
TAPE_DEVICE="${TAPE_DEVICE:-/dev/IBMtape3}"

TAPE="$TAPE_DEVICE"
API="/ws/scalari3_api"
MBUFFER="/usr/bin/mbuffer"
ITDT="/usr/local/bin/itdt"  # path to ITDT tool
MT="/usr/bin/mt"
OPF_UTIL="/aprun/shell/opf_util.sh"

# Remote base paths
DataArea="${DataArea:-/data_stored/}"
HistArea="${HistArea:-/data_old/}"

# DB credentials 
iUSERNAME="${iUSERNAME:-apusr1}";
iPASSWORD="${iPASSWORD:-1qaz2wsx}";
SrvName="FUTURES"
DbName="futures";
iDATABASE="futures";
iSERVER="FUTURES";

# Log & temp files
DAYNAME="$(date +%Y%m%d)"
LOGFILE="${LOGFILE:-/var/log/${OPNO}.${DAYNAME}.log}"
: > "$LOGFILE"

# Mail settings
MAIL_HEADER="[板橋交易] Scalari3 Backup <${JobID}> to Tape Notice"
SUBJECT="[板橋交易] Scalari3 Backup <${JobID}> to Tape Notice"
XTAG="[板橋交易] Scalari3 Backup <${JobID}> to Tape Notice"
MAIL_FROM="sysalert@taifex.com.tw"
recipients=(
    sys-linux@taifex.com.tw
    taifexop@taifex.com.tw
    sys-dba@taifex.com.tw
    sys-op@taifex.com.tw
)
MAIL_TO="${recipients[@]}"

# ===============================
# LOGGING FUNCTIONS
# ===============================
log() {
    local level="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$ts] [$level] $*"
    echo "$msg" | tee -a "$LOGFILE"

    for port in 9911 ; do
    {
        echo "📦$msg" | /usr/local/bin/socat -t 3 -T 5 - TCP:192.168.110.121:$port
    } &
    done

    # Only send email for ERROR or WARN level
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    {
	 echo "⚠  $msg" | /usr/local/bin/socat -t 3 -T 5 - TCP:192.168.110.121:9966
         echo "$msg" | /usr/local/bin/sendEmail -s 192.168.169.232 -o tls=no -o message-charset=utf-8 -o message-content-type=html -t sys-linux@taifex.com.tw -cc sys-dba@taifex.com.tw -bcc taifexop@taifex.com.tw -f sysalert@taifex.com.tw -l /var/log/sendEmail -a "$LOGFILE" -u "$MAIL_HEADER - $level - $msg" -m "$MAIL_HEADER - $level - $msg"
    } &
    fi
}
log_info(){ log INFO "$*"; }
log_ok(){ log OK "$*"; }
log_warn(){ log WARN "$*"; }
log_err(){ log ERROR "$*"; }

# ===============================
# ADJUST PATHS BASED ON OPNO
# ===============================

BASE_OPNO="${OPNO%AH}"

case "$BASE_OPNO" in
Z0303|Z0351|Z0352|Z0441|Z0442|Z0461|Z0462)
    [[ "$OPNO" == *AH ]] && SUFFIX="AH" || SUFFIX=""

    OPNO="$BASE_OPNO"
    JobID="${OPNO}${SUFFIX}"

    if [[ -n "$SUFFIX" ]]; then
        SrvName="FUTURESAH"
        iSERVER="FUTURESAH"
        DataArea="/data_storedah/"
        HistArea="/data_oldah/"
    else
        SrvName="FUTURES"
        iSERVER="FUTURES"
        DataArea="/data_stored/"
        HistArea="/data_old/"
    fi

    DbName="futures"
    iDATABASE="futures"
    ;;
*)
    log_info "[$JobID]: No backup defined for this OPNO."
    exit 0
    ;;    
esac

# Mail settings
MAIL_HEADER="[板橋交易] Scalari3 Backup <${JobID}> to Tape Notice"

if [[ "$OPNO" != "Z0441" && "$OPNO" != "Z0442" ]]; then
# ===============================
# OP RUNNABLE CHECK
# ===============================
for check in CHECK_CROSS_RUN_CODE CHECK_REP; do
	log_info "[$JobID]: Performing $SrvName $DbName cb $OPNO $check"
        if ! "$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" "$check"; then
            log_err "[$JobID]: $check failed"; exit 1
        fi
done
#
log_info "[$JobID]: Performing $SrvName $DbName cb $OPNO BEGIN_OPERATION"
#
"$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" BEGIN_OPERATION 2>/dev/null || true
#
fi

if [[ "$OPNO" == "Z0352" || "$JobID" == "Z0352AH" || "$JobID" == "Z0303AH" ]]; then
log_info "[$JobID]: Performing $SrvName $DbName cb $OPNO END_OPERATION_SUCCESS [RUN IN BACKGROUND]"
"$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" END_OPERATION_SUCCESS || log_warn "[$JobID]: END_OPERATION_SUCCESS hook failed [RUN IN BACKGROUND]"
log_info "[$JobID]: A new backup process, '$OPNO', runs in the background and is started [RUN IN BACKGROUND]"
fi

# ===============================
# ARCHIVE / MOVE STEP FOR Z0303
# ===============================
if [[ "$OPNO" == "Z0303" ]]; then
    log_info "[$JobID]: Performing archival/move steps..."
    #log_info "[$JobID]: isql -U "$iUSERNAME" -P "$iPASSWORD" -S "$iSERVER" -D "$iDATABASE" "
    log_info "[$JobID]: Determine OCF date..."
    Date=$(echo -e "select convert(varchar(10),OCF_DATE,112) FROM OCF\ngo" | isql -U"${iUSERNAME}" -P"${iPASSWORD}" -S"${iSERVER}" -D"${iDATABASE}" | grep -Eo '[0-9]{8}' | xargs )
    if [[ -z "$Date" ]]; then
        log_warn "[$JobID]: Could not determine OCF date; skipping move/delete."
        exit 1
    fi
    log_ok "[$JobID]: Determine OCF date = [$Date]"
    #
    # REMOTE_DEST="${HistArea%/}/test"
    REMOTE_DEST="${HistArea%/}/$Date"
    log_info "[$JobID]: Creating OCF DATE backup directory [$REMOTE_DEST]..."

    if ssh "${REMOTE_USER}@${HOST}" "mkdir -p '$REMOTE_DEST' && chown changer:op '$REMOTE_DEST' && chmod 777 '$REMOTE_DEST'"; then
        log_ok "[$JobID]: OCF DATE [$REMOTE_DEST] backup Directory available."
    else
        log_warn "[$JobID]: Failed to create/set permissions on directory [$REMOTE_DEST]; check manually."
    fi

    log_info "[$JobID]: Moving / Rsync data from [$DataArea] to [$REMOTE_DEST]., please wait ..."
    
    ssh "${REMOTE_USER}@${HOST}" "find '$DataArea' -maxdepth 1 -type f -printf '%P\0' 2>/dev/null | rsync -avc --itemize-changes --partial --remove-source-files --files-from=- --from0 --out-format='%n' '$DataArea' '$REMOTE_DEST/'" | tee -a "$LOGFILE" 2>&1
    #ssh "${REMOTE_USER}@${HOST}" "find '$DataArea' -maxdepth 1 -type f -printf '%P\0' 2>/dev/null | rsync -avc --itemize-changes --partial --files-from=- --from0 --out-format='%n' '$DataArea' '$REMOTE_DEST/'" | tee -a "$LOGFILE" 2>&1

    log_info "[$JobID]: ls -al --time-style=long-iso $REMOTE_DEST/"    
    ssh "${REMOTE_USER}@${HOST}" "ls -al --time-style=long-iso '$REMOTE_DEST/'" | tee -a "$LOGFILE" 2>&1

    log_ok "[$JobID]: Archival/move step finished."

    if [[ "$JobID" != "Z0303AH" ]]; then
    log_info "[$JobID]: Performing $SrvName $DbName cb $OPNO END_OPERATION_SUCCESS"
    "$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" END_OPERATION_SUCCESS || log_warn "[$JobID]: END_OPERATION_SUCCESS hook failed"
    fi

    echo "$MAIL_HEADER - [$JobID] - Completed" | /usr/local/bin/sendEmail -s 192.168.169.232 -o tls=no -o message-charset=utf-8 -o message-content-type=html -t sys-linux@taifex.com.tw -cc sys-dba@taifex.com.tw -bcc taifexop@taifex.com.tw -f sysalert@taifex.com.tw -l /var/log/sendEmail -a "$LOGFILE" -u "$MAIL_HEADER - [$JobID] - Completed" -m "$MAIL_HEADER - [$JobID] - Completed"

    exit 0;
fi

# ===============================
# DETERMINE BACKUP SOURCES FOR OTHER JOBS
# ===============================
bk_old=()
bk_oldah=()

case "$OPNO" in
Z0351|Z0352)
    API="/ws/prod/scalari3_api"
    TAPE_DEVICE="/dev/tape_prod"
    mapfile -t bk_old < <(
        ssh "${REMOTE_USER}@${HOST}" 'find /data_old -maxdepth 1 -mindepth 1 -type d -mtime -14 -regextype posix-extended -regex ".*/[0-9]{8}" -printf "%f\0" 2>/dev/null | sort -rz | while IFS= read -r -d "" dir; do
       if find "/data_old/$dir" -maxdepth 1 -type f \( -name "LOGdump*" -o -name "OPdump*" -o -name "DBdump*" -o -name "DDL*" \) -size +200000c -print -quit 2>/dev/null | grep -q .; then
                echo "/data_old/$dir"; break; fi; done'
    )
    mapfile -t bk_oldah < <(
        ssh "${REMOTE_USER}@${HOST}" 'find /data_oldah -maxdepth 1 -mindepth 1 -type d -mtime -14 -regextype posix-extended -regex ".*/[0-9]{8}" -printf "%f\0" 2>/dev/null | sort -rz | while IFS= read -r -d "" dir; do
         if find "/data_oldah/$dir" -maxdepth 1 -type f \( -name "LOGdump*" -o -name "OPdump*" -o -name "DBdump*" -o -name "DDL*" \) -size +200000c -print -quit 2>/dev/null | grep -q .; then
                echo "/data_oldah/$dir"; break; fi; done'
    )
    ;;
Z0461|Z0462)
    API="/ws/prod_daily/scalari3_api"
    TAPE_DEVICE="/dev/tape_cdrw"
    mapfile -t bk_old < <(
        ssh "${REMOTE_USER}@${HOST}" 'find /BQ_DATA_BK -maxdepth 1 -mindepth 1 -type d -mtime -14 -regextype posix-extended -regex ".*/[0-9]{4}_[0-1][0-9]_[0-3][0-9]" -printf "%f\0" 2>/dev/null | sort -rz | while IFS= read -r -d "" dir; do
            if find "/BQ_DATA_BK/$dir/CALX/" -maxdepth 1 -type f -name "*APLOG*.tar.gz" -size +200000c -print -quit 2>/dev/null | grep -q .; then
                echo "/BQ_DATA_BK/$dir"; break; fi; done'
    )
    mapfile -t bk_oldah < <(
        ssh "${REMOTE_USER}@${HOST}" 'find /BQ_DATA_BKAH -maxdepth 1 -mindepth 1 -type d -mtime -14 -regextype posix-extended -regex ".*/[0-9]{4}_[0-1][0-9]_[0-3][0-9]" -printf "%f\0" 2>/dev/null | sort -rz | while IFS= read -r -d "" dir; do
            if find "/BQ_DATA_BKAH/$dir/BAAH/" -maxdepth 1 -type f -name "*APLOG*.tar.gz" -size +200000c -print -quit 2>/dev/null | grep -q .; then
                echo "/BQ_DATA_BKAH/$dir"; break; fi; done'
    )
    ;;
Z0441|Z0442)
    API="/ws/prod_monthly/scalari3_api"
    TAPE_DEVICE="/dev/tape_cdrw"
    mapfile -t bk_old < <(
        ssh "${REMOTE_USER}@${HOST}" "find /BQ_DATA_BK -maxdepth 1 -type d -newermt \"$(date -d 'last month' +%Y-%m-01)\" ! -newermt \"$(date -d 'this month' +%Y-%m-01)\" -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2- | sort -t/ -k2,2 -s -k1,1r | xargs"
    )
    mapfile -t bk_oldah < <(
        ssh "${REMOTE_USER}@${HOST}" "find /BQ_DATA_BKAH -maxdepth 1 -type d -newermt \"$(date -d 'last month' +%Y-%m-01)\" ! -newermt \"$(date -d 'this month' +%Y-%m-01)\" -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2- | sort -t/ -k2,2 -s -k1,1r | xargs"
    )
    ;;
*)
    log_info "[$JobID]: No backup defined for this OPNO."
    exit 0
    ;;
esac

[[ ${#bk_old[@]} -eq 0 && ${#bk_oldah[@]} -eq 0 ]] && { log_err "[$JobID]: Nothing to backup"; exit 1; }

#exit 0 ; 
#
TAPE_DEVICE="$(ssh "${REMOTE_USER}@${HOST}" "/usr/bin/readlink -f '$TAPE_DEVICE'")"
TAPE="$TAPE_DEVICE"
#
# ===============================
# TAPE DEVICE HEALTH CHECK VIA ITDT
# ===============================
log_info "[$JobID]: Performing IBM ITDT tape health check on $TAPE_DEVICE ..."

log_info "[$JobID]: Check $ITDT -f $TAPE_DEVICE tur on $HOST"
# Run ITDT Test Unit Ready (TUR)
MEDIUM="$(ssh "${REMOTE_USER}@${HOST}" "$ITDT -f '$TAPE_DEVICE' tur | egrep -i 'No medium found' | wc -l")"
if [[ "$MEDIUM" -eq 0 ]]; then
    log_err "[$JobID]: Tape drive $TAPE (TUR failed). Check $ITDT -f '$TAPE_DEVICE' tur on $HOST"
    exit 1
else
    log_ok "[$JobID]: Tape drive $TAPE ready (No medium found)"
fi

log_info "[$JobID]: Check $ITDT -f $TAPE_DEVICE reqsense on $HOST"
# Run Request Sense to check for hardware errors
SENSE=$(ssh "${REMOTE_USER}@${HOST}" "$ITDT -f '$TAPE_DEVICE' reqsense 2>/dev/null || true")
if grep -q "04 00" <<< "$SENSE"; then
    log_err "[$JobID]: Tape drive reports hardware error on $TAPE_DEVICE."
    exit 1
else
    log_ok "[$JobID]: Tape drive reports hardware OK on $TAPE_DEVICE."
fi

log_info "[$JobID]: Check test -w $TAPE_DEVICE on $HOST"
# Verify device is writable
if ! ssh "${REMOTE_USER}@${HOST}" test -w "$TAPE_DEVICE"; then
    log_err "[$JobID]: Tape device $TAPE_DEVICE not writable."
    exit 1
else
    log_ok "[$JobID]: Tape device $TAPE_DEVICE is writable"
fi

log_ok "[$JobID]: Tape device $TAPE_DEVICE passed ITDT health checks."

# ===============================
# LOAD TAPE
# ===============================
log_info "[$JobID]: Loading tape to drive $TAPE_DEVICE ..."
"$API" load_tape >> "$LOGFILE" 2>&1 && log_ok "[$JobID]: Tape loaded." || { log_err "[$JobID]: Failed to load tape"; exit 1; }

log_info "[$JobID]: Check Tape device $TAPE_DEVICE is become ready within 120 seconds..."
sleep 30;

# 1. ready check
ssh "${REMOTE_USER}@${HOST}" "$ITDT -f '$TAPE_DEVICE' tur >/dev/null 2>&1"
RC=$?
if [ $RC -ne 0 ]; then
    log_err "[$JobID]: $TAPE_DEVICE TUR Test ExitCode = $RC, Tape drive not ready"
    exit 1
fi

# 2. TapeAlert check
OUT=$(ssh "${REMOTE_USER}@${HOST}" "$ITDT -f '$TAPE_DEVICE' logpage 0x2e 2>/dev/null")

HEX=$(echo "$OUT" | awk '/^[[:space:]]*[0-9A-Fa-f]{4} -/{
    sub(/^.*- /,"")
    sub(/  \[.*$/,"")
    print
}' | tr -d ' \n')

[ -z "$HEX" ] && log_err "[$JobID]: $TAPE_DEVICE No TapeAlert data" && exit 1

mapfile -t B < <(echo "$HEX" | grep -o '..')

for ((i=4; i+4<${#B[@]}; i+=5)); do
    if [ "${B[i+4]}" != "00" ]; then
        log_err "[$JobID]: $TAPE_DEVICE TapeAlert set at code ${B[i]}${B[i+1]} value=${B[i+4]}"
        exit 1
    fi
done

log_ok "[$JobID]: $TAPE_DEVICE drive ready and TapeAlert clear"

#STATUS=$(ssh "${REMOTE_USER}@${HOST}" "/usr/bin/mt -f '$TAPE_DEVICE' status 2>&1 || true")
#if grep -q "DR_OPEN" <<< "$STATUS"; then
#    log_err "[$JobID]: Tape drive empty or door open"
#    exit 1
#fi
log_ok "[$JobID]: Tape drive is ready"

#ssh "${REMOTE_USER}@${HOST}" "$MT -f '$TAPE_DEVICE' rewind && $MT -f '$TAPE_DEVICE' setblk 0" 2>/dev/null
#ssh "${REMOTE_USER}@${HOST}" "sync ; echo 3 > /proc/sys/vm/drop_caches ; echo 1 > /proc/sys/vm/compact_memory" 2>/dev/null
ssh "${REMOTE_USER}@${HOST}" "sync ; echo 1 > /proc/sys/vm/compact_memory" 2>/dev/null

# ===============================
# BACKUP TO TAPE
# ===============================
BUFFER_MEM="8G"
BLOCK_SIZE="1M"
all_dirs=("${bk_old[@]}" "${bk_oldah[@]}")

log_info "[$JobID]: Beginning backup to tape..."
log_info "[$JobID]: Writing ${all_dirs[@]} directories to $TAPE_DEVICE ,Please wait..."
log_info "[$JobID]: tar -cvf - ${all_dirs[@]} | $MBUFFER -m $BUFFER_MEM -s $BLOCK_SIZE -o $TAPE_DEVICE"

if ssh "${REMOTE_USER}@${HOST}" "tar -cvf - ${all_dirs[@]} | $MBUFFER -m $BUFFER_MEM -s $BLOCK_SIZE -o $TAPE_DEVICE 2>/dev/null" >> "$LOGFILE" 2>&1
then
    log_ok "[$JobID]: Backup completed successfully with mbuffer."
else
    log_err "[$JobID]: Backup failed during tar->mbuffer->tape."
    exit 1
fi

# ===============================
# UNLOAD TAPE
# ===============================
log_info "[$JobID]: Unloading tape from drive $TAPE_DEVICE ..."

"$API" unload >> "$LOGFILE" 2>&1 && log_ok "[$JobID]: Tape unloaded." || log_warn "[$JobID]: Tape unload returned non-zero"

# ===============================
# END OPERATION
# ===============================
if [[ "$OPNO" != "Z0441" && "$OPNO" != "Z0442" && "$OPNO" != "Z0352" && "$JobID" != "Z0352AH" && "$JobID" != "Z0303AH" ]]; then
log_info "[$JobID]: Performing $SrvName $DbName cb $OPNO END_OPERATION_SUCCESS"
"$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" END_OPERATION_SUCCESS || log_warn "[$JobID]: END_OPERATION_SUCCESS hook failed"
fi

log_ok "[$JobID]: Backup job finished successfully."

# ===============================
# FINAL MAIL SUMMARY
# ===============================

echo "$MAIL_HEADER - [$JobID] - Completed" | /usr/local/bin/sendEmail -s 192.168.169.232 -o tls=no -o message-charset=utf-8 -o message-content-type=html -t sys-linux@taifex.com.tw -cc sys-dba@taifex.com.tw -bcc taifexop@taifex.com.tw -f sysalert@taifex.com.tw -l /var/log/sendEmail -a "$LOGFILE" -u "$MAIL_HEADER - [$JobID] - Completed" -m "$MAIL_HEADER - [$JobID] - Completed"

MAIL_HEADER="📊 [板橋交易] Scalari3 Backup [${JobID}] to Tape Notice"
echo "$MAIL_HEADER - [$JobID] - Completed" | /usr/bin/s-nail -r sysalert@taifex.com.tw -s "$MAIL_HEADER - [$JobID] - Completed" -a "$LOGFILE" jeffreyhu@taifex.com.tw

exit 0
