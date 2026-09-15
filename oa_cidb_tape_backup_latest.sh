#!/usr/bin/env bash

PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH

# ================= CONFIG =================
MAIL_HEADER="📤[企業內部][Z0361OA] Scalari3 Backup OA/CIDB to Tape Notice"
MAIL_FROM="sysalert@taifex.com.tw"
recipients=(
    sys-linux@taifex.com.tw
    sys-dba@taifex.com.tw
    sys-op@taifex.com.tw
    sysalert@taifex.com.tw
)
MAIL_TO="${recipients[@]}"

BASE="/cidbtmp"
EXTRA_DIR1="/oa_backup"
EXTRA_DIR2="/data_stored"
TAPE="$(readlink -f /dev/tapedrv_oa)"
API="/aprun/shell/scalari3_api"
MBUFFER="/usr/bin/mbuffer"
ITDT="/usr/local/bin/itdt"  # path to ITDT tool
MT="/usr/bin/mt"

BUFFER_MEM="6G"
BLOCK_SIZE="1M"

OPNO="${1:-Z0361OA}"
JobID="${OPNO}"
#DAYNAME="$(date +%A)"
DAYNAME="$(date +%Y%m%d)"
LOGFILE="/var/log/${OPNO}.${DAYNAME}.log"
: > "$LOGFILE"

# ================= LOGGING =================
log() {
    local level="$1"; shift
    local ts msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="[$ts] [$level] [$JobID] $*"

    echo "$msg" | tee -a "$LOGFILE"
    
    for port in 9911 ; do
    {
        echo "📦$msg" | /usr/local/bin/socat -t 3 -T 5 - TCP:192.168.167.68:$port
    } &
    done
   
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    {
	 echo "📦$msg" | /usr/local/bin/socat -t 3 -T 5 - TCP:192.168.167.68:9966
         echo "$msg" | mail -s "$MAIL_HEADER - $level - $msg" -a "$LOGFILE" -r "$MAIL_FROM" $MAIL_TO
    } &
    fi

}
log_info(){ log INFO "$*"; }
log_ok(){ log OK "$*"; }
log_warn(){ log WARN "$*"; }
log_err(){ log ERROR "$*"; }

# ================= FIND LATEST =================
LATEST_NAME=$(find "$BASE" -maxdepth 1 -type d \
  -regextype posix-extended \
  -regex ".*/[0-9]{4}-[0-9]{2}-[0-9]{2}" \
  -printf "%f\n" | sort -r | head -n1)

if [[ -z "$LATEST_NAME" ]]; then
    log_warn "No YYYY-MM-DD directory found under $BASE"
    exit 0
fi

LATEST_DIR="$BASE/$LATEST_NAME"

# Verify it's actually a directory
if [[ ! -d "$LATEST_DIR" ]]; then
    log_err "LATEST_NAME [$LATEST_NAME] is not a directory (or does not exist). Skipping."
    exit 1
fi

DBA_FILE="$LATEST_DIR/DBA-complete.txt"
COSE_FILE="$LATEST_DIR/COSE-complete.txt"
COUNT=0;

for h in 1 2 ;
do

icount=1;
icheck=1;
warn_times=3;

while [ $icheck ];
do
	
#
MISSING_ITEMS=()

# Check DBA file
if [[ ! -f "$DBA_FILE" ]]; then
    MISSING_ITEMS+=("DBA_FILE")
fi

# Check COSE file (skip if already exists)
if [[ -f "$COSE_FILE" ]]; then
    MISSING_ITEMS+=("COSE_FILE already exists")
fi

if [[ ${#MISSING_ITEMS[@]} -gt 0 ]]; then
    log_warn "[$h] Backup conditions not met. Skipping. Missing/Invalid: ${MISSING_ITEMS[*]} (DBA=$DBA_FILE, COSE=$COSE_FILE)"
    ((icount++));
    sleep 1800 ; 
fi

if [[ "$icount" -gt "$warn_times" ]]; then
  icheck=0;
  log_warn "[$h] Backup conditions not met exceeds $warn_times times. [EXIT] Skipping. Missing/Invalid: ${MISSING_ITEMS[*]} (DBA=$DBA_FILE, COSE=$COSE_FILE)"
  exit 0;
fi

done

#
sync
#echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
#
log_info "[$h] Selected CIDB directory: $LATEST_DIR"
log_info "[$h] Including extra OA directory 1: $EXTRA_DIR1"
log_info "[$h] Including extra OA directory 2: $EXTRA_DIR2"

# ================= ITDT HEALTH CHECK =================
#log_info "[$h] Performing IBM ITDT tape health check on $TAPE..."

#log_info "[$h] Check $ITDT -f $TAPE tur"
# Test Unit Ready
#MEDIUM="$("$ITDT" -f "$TAPE" tur | egrep -i 'No medium found' | wc -l)"
#if [[ "$MEDIUM" -eq 0 ]]; then
#    log_err "[$h] Tape drive $TAPE test unit failed. Check $ITDT -f $TAPE tur"
#    exit 1
#else
#    log_ok "[$h] Tape drive $TAPE test unit ready. No medium found"
#fi

#log_info "[$h] Check $ITDT -f $TAPE reqsense"
# Request Sense
#SENSE="$("$ITDT" -f "$TAPE" reqsense 2>/dev/null || true)"
#if grep -q "04 00" <<< "$SENSE"; then
#    log_err "[$h] Tape drive $TAPE reports hardware error"
#    exit 1
#else
#    log_ok "[$h] Tape drive $TAPE reports hardware ok"
#fi

# Check if tape is writable
if ! test -w "$TAPE"; then
    log_err "[$h] Tape device $TAPE not writable"
    exit 1
else
    log_ok "[$h] Tape device $TAPE is writable"
fi

# ================= LOAD TAPE =================
log_info "[$h] Loading tape to drive $TAPE ..."
"$API" load_tape >> "$LOGFILE" 2>&1 && log_ok "[$h] Tape loaded." || { log_err "[$h] Failed to load tape"; exit 1; }

log_info "[$h] check Tape device $TAPE is online/ready, waiting for 30 seconds..."
sleep 30;

# 1. ready check
#"$ITDT" -f "$TAPE" tur >/dev/null 2>&1
#RC=$?
#if [ $RC -ne 0 ]; then
#    log_err "[$h] $TAPE TUR Test code = $RC , drive not ready"
#    exit 1
#fi

# 2. TapeAlert check
#OUT=$("$ITDT" -f "$TAPE" logpage 0x2e 2>/dev/null)

#HEX=$(echo "$OUT" | awk '/^[[:space:]]*[0-9A-Fa-f]{4} -/{
#    sub(/^.*- /,"")
#    sub(/  \[.*$/,"")
#    print
#}' | tr -d ' \n')

#[ -z "$HEX" ] && log_err "[$h] no TapeAlert data" && exit 1

#mapfile -t B < <(echo "$HEX" | grep -o '..')

#for ((i=4; i+4<${#B[@]}; i+=5)); do
#    if [ "${B[i+4]}" != "00" ]; then
#        log_err "[$h] TapeAlert set at code ${B[i]}${B[i+1]} value=${B[i+4]}"
#        exit 1
#    fi
#done

#log_ok "[$h] drive ready and TapeAlert clear"

#STATUS="$("$MT" -f "$TAPE" status 2>&1 || true)"
#if grep -q "DR_OPEN" <<< "$STATUS"; then
#    log_err "[$h] Tape drive empty or door open"
#    exit 1
#else
    log_ok "[$h] Tape drive is ready"
#fi

#"$MT" -f "$TAPE" rewind   &>/dev/null
#"$MT" -f "$TAPE" setblk 0 &>/dev/null      # Variable block mode
#"$MT" -f "$TAPE" compression 1 &>/dev/null # Enable hardware compression

log_info "[$h] Starting tar -> mbuffer -> tape"
log_info "[$h] tar -cf - -C "$BASE" "$LATEST_NAME" -C / "$(basename "$EXTRA_DIR1")" -C / "$(basename "$EXTRA_DIR2")" | "$MBUFFER" -m "$BUFFER_MEM" -s "$BLOCK_SIZE" -o "$TAPE" "

if tar -cf - -C "$BASE" "$LATEST_NAME" -C / "$(basename "$EXTRA_DIR1")" -C / "$(basename "$EXTRA_DIR2")" | "$MBUFFER" -m "$BUFFER_MEM" -s "$BLOCK_SIZE" -o "$TAPE"
then
    log_ok "[$h] Backup successful"
    COUNT=$h
else
    log_err "[$h] Backup failed during tar/mbuffer"
    exit 1
fi

log_info "[$h] Unloading tape from drive $TAPE ..."
"$API" unload >> "$LOGFILE" 2>&1 && log_ok "[$h] Tape unloaded." || log_warn "[$h] Tape unload returned non-zero"

done

# After loop: create marker only if both backups succeeded
if [[ "$COUNT" -gt 1 ]] ; then
    touch "$COSE_FILE"
    log_info "Marker file created: $COSE_FILE"
#
    HOST="${HOST:-times-bk}"
    REMOTE_USER="${REMOTE_USER:-root}"
    DataArea="/data_stored/";
    HistArea="/data_old/";
    Date=$(date +"%Y%m%d");
    #
    log_info "[*] Performing archival/move steps..."
    log_ok "[*] Determine OCF date = [$Date]"
    #
    REMOTE_DEST="${HistArea%/}/$Date"
    log_info "[*] Creating OCF DATE backup directory [$REMOTE_DEST]..."
    #
    if ssh "${REMOTE_USER}@${HOST}"  "mkdir -p '$REMOTE_DEST' && chown changer:op '$REMOTE_DEST' && chmod 777 '$REMOTE_DEST'"; then
        log_ok "[*] OCF DATE [$REMOTE_DEST] backup Directory available."
    else
        log_warn "[*] Failed to create/set permissions on directory [$REMOTE_DEST]; check manually."
	mkdir -p $REMOTE_DEST && chown changer:op $REMOTE_DEST && chmod 777 $REMOTE_DEST 
    fi

    log_info "[*] Moving / Rsync data from [$DataArea] to [$REMOTE_DEST]., please wait ..."

    #exit 0;

    ssh "${REMOTE_USER}@${HOST}" "find '$DataArea' -maxdepth 1 -type f -printf '%P\0' 2>/dev/null | rsync -avc --itemize-changes --partial --remove-source-files --files-from=- --from0 --out-format='%n' '$DataArea' '$REMOTE_DEST/'" | tee -a "$LOGFILE" 2>&1

    log_info "[*]: ls -al --time-style=long-iso $REMOTE_DEST/"
    ssh "${REMOTE_USER}@${HOST}" "ls -al --time-style=long-iso '$REMOTE_DEST/'" | tee -a "$LOGFILE" 2>&1

    log_ok "[*] Archival/move step finished."
#
else
    log_warn "WARNING: Not all tapes completed successfully. Marker not created."
fi
####
sync
#echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
#
log_ok "Tape backup job completed"

echo "$MAIL_HEADER - [$JobID] - Completed" | mail -s "$MAIL_HEADER - [$JobID] - Completed" -a "$LOGFILE" -r "$MAIL_FROM" $MAIL_TO

for h in /ws/cookies.txt /root/cookies.txt ; do [ -r "$h" ] || continue; /usr/bin/curl -sk -b $h -H "Accept: application/json" -H "Content-Type: application/json" "https://192.168.175.31/aml/users/sessions" | jq -r '.userSession[]? | select(.loginFrom == "192.168.169.101") | .id' | xargs -r -I {} /usr/bin/curl -sk -b $h -X DELETE "https://192.168.175.31/aml/users/session/{}" ; done

exit 0
