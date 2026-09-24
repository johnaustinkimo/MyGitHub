#!/usr/bin/env bash
# Scalar i3 tape-write CLI wrapper
# Version: 1.3
#
# Existing robotics backend:
#   scalari3_api_ops load_tape
#   scalari3_api_ops unload
#
# Data path:
#   NFS 192.168.167.214:/tapedir -> /mnt/tmp
#   backup directories matching /mnt/tmp/*L7
#   tape device symlink /dev/tapedrv_test -> /dev/IBMtapeX
#
# Safety policy:
#   - verify the NFS source before reading
#   - verify backup directories before loading tape
#   - refuse robotics load if the Linux tape drive already contains media
#   - only load when an explicit empty-drive state is detected
#   - verify the Linux tape device after robotics load
#   - rewind before writing
#   - never unload after tar/verification failure
#   - unload only after a successful write/verification unless --keep is used
#   - redact backend password fields from wrapper output/logs
#   - emit periodic write heartbeat for WebSocket/UI observability
#   - record source bytes, ownership warning, elapsed time and average throughput

set -uo pipefail

VERSION="1.3"

# ----------------------------- Defaults ---------------------------------
API_BIN="${SCALARI3_API_BIN:-/ws/ts4500Toscalari3/scalari3_api_ops}"
NFS_SOURCE="${SCALARI3_NFS_SOURCE:-192.168.167.214:/tapedir}"
NFS_MOUNT="${SCALARI3_NFS_MOUNT:-/mnt/tmp}"
TAPE_LINK="${SCALARI3_TAPE_DEVICE:-/dev/tapedrv_test}"
DIR_PATTERN="${SCALARI3_DIR_PATTERN:-*L7}"
LOG_DIR="${SCALARI3_LOG_DIR:-/var/log/scalari3_tape_write}"
LOCK_FILE="${SCALARI3_LOCK_FILE:-/var/lock/scalari3_tape_write.lock}"
LOAD_WAIT_SEC="${SCALARI3_LOAD_WAIT_SEC:-180}"
POLL_SEC="${SCALARI3_POLL_SEC:-3}"
VERIFY_MODE="${SCALARI3_VERIFY_MODE:-probe}"  # none|probe|full
PROBE_ENTRIES="${SCALARI3_PROBE_ENTRIES:-20}"
HEARTBEAT_SEC="${SCALARI3_HEARTBEAT_SEC:-60}"
KEEP_LOADED=0
DRY_RUN=0

SELECTED_TAPE=""
RESOLVED_TAPE=""
RUN_LOG=""
SOURCE_BYTES=0
WRITE_ELAPSED_SEC=0
WRITE_AVG_MIB=0
SOURCE_OWNER_SUMMARY="UNKNOWN"

# Filled by collect_backup_dirs()
BACKUP_DIRS=()

# ------------------------------ Helpers ---------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s [INFO] %s\n' "$(ts)" "$*" >&2; }
ok()  { printf '%s [OK] %s\n'   "$(ts)" "$*" >&2; }
warn(){ printf '%s [WARN] %s\n' "$(ts)" "$*" >&2; }
err() { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die() { local rc="$1"; shift; err "$*"; exit "$rc"; }

usage() {
  cat <<USAGE
Scalar i3 tape-write CLI wrapper v${VERSION}

Usage:
  $0 scan
  $0 nfs-status
  $0 tape-status
  $0 drive-empty
  $0 precheck
  $0 load
  $0 write [options]
  $0 unload
  $0 run [options]

Commands:
  scan        List backup directories under NFS matching '${DIR_PATTERN}'.
  nfs-status  Verify ${NFS_MOUNT} is mounted from ${NFS_SOURCE}.
  tape-status Show resolved tape device and mt status.
  drive-empty Check whether the Linux tape drive is explicitly empty.
  precheck    Verify NFS/source directories and show the resolved tape device + load safety state.
  load        Empty-drive precheck, then call 'scalari3_api_ops load_tape' and wait for OS tape ONLINE.
  write       Write all matching backup directories to the currently loaded tape.
  unload      Call existing 'scalari3_api_ops unload'.
  run         Production flow: scan -> load -> write -> verify -> unload.

Options:
  --api-bin PATH        Robotics CLI. Default: ${API_BIN}
  --nfs-source SRC      Expected NFS source. Default: ${NFS_SOURCE}
  --nfs-mount PATH      NFS mount point. Default: ${NFS_MOUNT}
  --tape-device PATH    Tape symlink/device. Default: ${TAPE_LINK}
  --pattern GLOB        Backup directory basename pattern. Default: ${DIR_PATTERN}
  --verify MODE         none | probe | full. Default: ${VERIFY_MODE}
  --probe-entries N     Entries displayed by probe verification. Default: ${PROBE_ENTRIES}
  --heartbeat-sec N     Write progress heartbeat interval. Default: ${HEARTBEAT_SEC}
  --keep                Keep cartridge loaded after successful 'run'.
  --dry-run             Print destructive/write commands without executing them.
  --version             Print version.
  -h, --help            Show this help.

Examples:
  $0 scan
  $0 drive-empty
  $0 precheck
  $0 run
  $0 run --verify full
  $0 run --keep
  $0 write --verify probe

Archive layout example:
  /mnt/tmp/OAT016L7/...  -> tape path OAT016L7/...
  /mnt/tmp/CDT015L7/...  -> tape path CDT015L7/...
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die 10 "Required command not found: $1"
}

run_cmd() {
  if (( DRY_RUN )); then
    printf '%s [DRYRUN] ' "$(ts)" >&2
    printf '%q ' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}


redact_sensitive_stream() {
  # Mask common JSON/password forms emitted by the existing Scalar i3 backend.
  # This protects terminal/WebSocket/log output handled by this wrapper.
  sed -E \
    -e 's/("password"[[:space:]]*:[[:space:]]*")[^"]*(")/\1********\2/g' \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][=:][[:space:]]*)[^[:space:]]+/\1********/g'
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die 11 "This operation must run as root"
}

ensure_api_bin() {
  # Also support placing wrapper beside scalari3_api_ops.
  if [[ ! -x "$API_BIN" ]]; then
    local beside
    beside="$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/scalari3_api_ops"
    if [[ -x "$beside" ]]; then
      API_BIN="$beside"
    fi
  fi
  [[ -x "$API_BIN" ]] || die 12 "Scalar i3 backend not executable: $API_BIN"
}

verify_nfs() {
  need_cmd findmnt
  local line src fstype target
  line="$(findmnt -rn -T "$NFS_MOUNT" -o SOURCE,FSTYPE,TARGET 2>/dev/null | head -n1)"
  [[ -n "$line" ]] || die 20 "No mounted filesystem found for $NFS_MOUNT"

  read -r src fstype target <<<"$line"
  [[ "$target" == "$NFS_MOUNT" ]] || die 21 "Expected mount target '$NFS_MOUNT', actual='$target'"
  [[ "$fstype" == "nfs" || "$fstype" == "nfs4" ]] || die 22 "Expected NFS filesystem at $NFS_MOUNT, actual type='$fstype'"
  [[ "$src" == "$NFS_SOURCE" ]] || die 23 "NFS source mismatch: expected='$NFS_SOURCE' actual='$src'"
  [[ -d "$NFS_MOUNT" && -r "$NFS_MOUNT" && -x "$NFS_MOUNT" ]] || die 24 "NFS mount is not readable/searchable: $NFS_MOUNT"

  ok "NFS verified: source=$src type=$fstype target=$target"
}

collect_backup_dirs() {
  verify_nfs
  BACKUP_DIRS=()

  local base path
  while IFS= read -r -d '' path; do
    base="${path##*/}"
    [[ -n "$base" ]] || continue
    BACKUP_DIRS+=("$base")
  done < <(find "$NFS_MOUNT" -mindepth 1 -maxdepth 1 -type d -name "$DIR_PATTERN" -print0 2>/dev/null | sort -z)

  (( ${#BACKUP_DIRS[@]} > 0 )) || die 30 "No backup directories found: ${NFS_MOUNT}/${DIR_PATTERN}"

  local d
  for d in "${BACKUP_DIRS[@]}"; do
    [[ -r "$NFS_MOUNT/$d" && -x "$NFS_MOUNT/$d" ]] || die 31 "Backup directory not readable/searchable: $NFS_MOUNT/$d"
  done
}

print_backup_dirs() {
  collect_backup_dirs
  printf '%-4s %-24s %s\n' "NO." "VOLSER-DIR" "PATH"
  printf '%-4s %-24s %s\n' "----" "------------------------" "----"
  local i=0 d
  for d in "${BACKUP_DIRS[@]}"; do
    i=$((i+1))
    printf '%-4d %-24s %s\n' "$i" "$d" "$NFS_MOUNT/$d"
  done
  printf '\nTotal directories: %d\n' "${#BACKUP_DIRS[@]}"
}

resolve_tape_device() {
  [[ -e "$TAPE_LINK" || -L "$TAPE_LINK" ]] || die 40 "Tape device/symlink not found: $TAPE_LINK"
  RESOLVED_TAPE="$(readlink -f -- "$TAPE_LINK" 2>/dev/null || true)"
  [[ -n "$RESOLVED_TAPE" ]] || die 41 "Unable to resolve tape device: $TAPE_LINK"
  [[ -c "$RESOLVED_TAPE" ]] || die 42 "Resolved tape device is not a character device: $RESOLVED_TAPE"
  log "Tape device: $TAPE_LINK -> $RESOLVED_TAPE"
}

mt_status_raw() {
  resolve_tape_device
  mt -f "$RESOLVED_TAPE" status 2>&1
}

show_tape_status() {
  need_cmd mt
  resolve_tape_device
  printf 'Tape Link     : %s\n' "$TAPE_LINK"
  printf 'Resolved      : %s\n' "$RESOLVED_TAPE"
  printf 'OS Status     :\n'
  mt -f "$RESOLVED_TAPE" status
}

# Globals populated by probe_drive_media_state().
DRIVE_MEDIA_STATE="UNKNOWN"   # EMPTY|LOADED|UNKNOWN
DRIVE_STATUS_RC=0
DRIVE_STATUS_OUTPUT=""

probe_drive_media_state() {
  need_cmd mt
  resolve_tape_device

  DRIVE_MEDIA_STATE="UNKNOWN"
  DRIVE_STATUS_RC=0
  DRIVE_STATUS_OUTPUT=""

  if DRIVE_STATUS_OUTPUT="$(mt -f "$RESOLVED_TAPE" status 2>&1)"; then
    DRIVE_STATUS_RC=0
  else
    DRIVE_STATUS_RC=$?
  fi

  # A loaded IBM tape reports ONLINE. BOT may or may not be present depending
  # on current tape position, therefore ONLINE alone is sufficient to refuse
  # another robotics load.
  if grep -Eq '(^|[[:space:]])ONLINE([[:space:]]|$)' <<<"$DRIVE_STATUS_OUTPUT"; then
    DRIVE_MEDIA_STATE="LOADED"
    return 0
  fi

  # Require an explicit no-media indication before considering the drive empty.
  # Typical Linux mt/IBM tape-driver output uses DR_OPEN for no cartridge.
  # Also accept common explicit "no medium/no tape" messages from mt/ioctl.
  if grep -Eiq '(^|[[:space:]])DR_OPEN([[:space:]]|$)|no[[:space:]_-]+medium|no[[:space:]_-]+media|no[[:space:]_-]+tape|medium[[:space:]_-]+not[[:space:]_-]+present|tape[[:space:]_-]+not[[:space:]_-]+present' <<<"$DRIVE_STATUS_OUTPUT"; then
    DRIVE_MEDIA_STATE="EMPTY"
    return 0
  fi

  return 0
}

show_drive_empty() {
  probe_drive_media_state
  printf 'Tape Link     : %s\n' "$TAPE_LINK"
  printf 'Resolved      : %s\n' "$RESOLVED_TAPE"
  printf 'Media State   : %s\n' "$DRIVE_MEDIA_STATE"
  printf 'mt Status RC  : %s\n' "$DRIVE_STATUS_RC"
  printf 'OS Status     :\n%s\n' "$DRIVE_STATUS_OUTPUT"

  case "$DRIVE_MEDIA_STATE" in
    EMPTY)
      ok "Drive-empty precheck PASSED: $RESOLVED_TAPE has no loaded media"
      return 0
      ;;
    LOADED)
      err "Drive-empty precheck FAILED: $RESOLVED_TAPE already contains media"
      return 45
      ;;
    *)
      err "Drive-empty precheck INDETERMINATE: refusing robotics load because empty state was not explicit"
      return 46
      ;;
  esac
}

require_drive_empty() {
  probe_drive_media_state

  case "$DRIVE_MEDIA_STATE" in
    EMPTY)
      ok "Drive-empty precheck PASSED: $TAPE_LINK -> $RESOLVED_TAPE is explicitly empty"
      ;;
    LOADED)
      err "Drive-empty precheck FAILED: tape device is already ONLINE; refusing Scalar i3 load_tape"
      printf '%s\n' "$DRIVE_STATUS_OUTPUT" >&2
      die 45 "Unload the existing cartridge first, then retry"
      ;;
    *)
      err "Unable to prove that the tape drive is empty; refusing Scalar i3 load_tape"
      printf '%s\n' "$DRIVE_STATUS_OUTPUT" >&2
      die 46 "Expected an explicit empty/no-media state such as DR_OPEN; mt_rc=$DRIVE_STATUS_RC"
      ;;
  esac
}

wait_tape_online() {
  need_cmd mt
  resolve_tape_device

  local deadline now out
  deadline=$(( $(date +%s) + LOAD_WAIT_SEC ))
  while :; do
    out="$(mt -f "$RESOLVED_TAPE" status 2>&1 || true)"
    if grep -Eq '(^|[[:space:]])ONLINE([[:space:]]|$)' <<<"$out"; then
      ok "OS tape device ONLINE: $RESOLVED_TAPE"
      return 0
    fi
    now=$(date +%s)
    (( now >= deadline )) && {
      err "Tape device did not become ONLINE within ${LOAD_WAIT_SEC}s: $RESOLVED_TAPE"
      printf '%s\n' "$out" >&2
      return 1
    }
    sleep "$POLL_SEC"
  done
}

rewind_tape() {
  resolve_tape_device
  log "Rewinding tape: $RESOLVED_TAPE"
  run_cmd mt -f "$RESOLVED_TAPE" rewind || die 43 "Tape rewind failed: $RESOLVED_TAPE"

  if (( ! DRY_RUN )); then
    local st
    st="$(mt -f "$RESOLVED_TAPE" status 2>&1 || true)"
    grep -Eq '(^|[[:space:]])ONLINE([[:space:]]|$)' <<<"$st" || {
      printf '%s\n' "$st" >&2
      die 44 "Tape is not ONLINE after rewind"
    }
    if grep -Eq '(^|[[:space:]])BOT([[:space:]]|$)' <<<"$st"; then
      ok "Tape rewound to BOT/ONLINE"
    else
      warn "Tape is ONLINE but mt output did not explicitly report BOT"
    fi
  fi
}

parse_selected_tape() {
  # Expected example:
  # [OK] Selected tape: [CDT002L9] @ {...}
  local f="$1"
  SELECTED_TAPE="$(sed -n 's/.*Selected tape: \[\([^]]\+\)\].*/\1/p' "$f" | tail -n1)"
  if [[ -z "$SELECTED_TAPE" ]]; then
    # Fallback from a later log line:
    # loading tape [CDT002L9] -> drive [...]
    SELECTED_TAPE="$(sed -n 's/.*loading tape \[\([^]]\+\)\].*/\1/p' "$f" | tail -n1)"
  fi
}

api_load() {
  ensure_api_bin
  require_root
  need_cmd tee
  need_cmd mt

  # v1.1 safety gate: never ask Scalar i3 robotics to load media into a
  # Linux-visible drive that already contains a cartridge. An UNKNOWN state is
  # also rejected; production automation proceeds only from an explicit EMPTY.
  require_drive_empty

  mkdir -p "$LOG_DIR" 2>/dev/null || true
  local loadlog rc
  loadlog="${LOG_DIR}/load_$(date +%Y%m%d_%H%M%S).log"

  log "Calling Scalar i3 robotics load_tape: $API_BIN load_tape"
  if (( DRY_RUN )); then
    run_cmd "$API_BIN" load_tape
    SELECTED_TAPE="DRYRUN"
    return 0
  fi

  set +e
  "$API_BIN" load_tape 2>&1 | redact_sensitive_stream | tee "$loadlog"
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) || die 50 "Scalar i3 load_tape failed: rc=$rc log=$loadlog"

  parse_selected_tape "$loadlog"
  if [[ -n "$SELECTED_TAPE" ]]; then
    ok "Scalar i3 reports loaded cartridge: $SELECTED_TAPE"
  else
    warn "load_tape succeeded but cartridge barcode could not be parsed from output"
  fi

  wait_tape_online || die 51 "Robotics load succeeded but Linux tape device is not ONLINE"
}

api_unload() {
  ensure_api_bin
  require_root

  log "Calling Scalar i3 robotics unload: $API_BIN unload"
  if (( DRY_RUN )); then
    run_cmd "$API_BIN" unload
    return 0
  fi

  local rc unloadlog
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  unloadlog="${LOG_DIR}/unload_$(date +%Y%m%d_%H%M%S).log"
  set +e
  "$API_BIN" unload 2>&1 | redact_sensitive_stream | tee "$unloadlog"
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) || die 52 "Scalar i3 unload failed: rc=$rc"
  ok "Scalar i3 unload completed"
}

collect_source_metrics() {
  SOURCE_BYTES=0
  SOURCE_OWNER_SUMMARY="UNKNOWN"

  local d path owner owners=()
  for d in "${BACKUP_DIRS[@]}"; do
    path="$NFS_MOUNT/$d"
    owner="$(stat -c '%U:%G' -- "$path" 2>/dev/null || echo UNKNOWN:UNKNOWN)"
    owners+=("$d=$owner")
  done
  SOURCE_OWNER_SUMMARY="${owners[*]}"

  local paths=()
  for d in "${BACKUP_DIRS[@]}"; do
    paths+=("$NFS_MOUNT/$d")
  done
  SOURCE_BYTES="$(du -sb -- "${paths[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%.0f",s+0}')"
  [[ "$SOURCE_BYTES" =~ ^[0-9]+$ ]] || SOURCE_BYTES=0

  local item
  for item in "${owners[@]}"; do
    if [[ "$item" == *=nobody:* || "$item" == *:nobody ]]; then
      warn "Source ownership warning: $item; new tape will preserve CURRENT NFS ownership, not original TS4500 UID/GID metadata"
    fi
  done

  log "Source apparent bytes: $SOURCE_BYTES"
  log "Source ownership    : $SOURCE_OWNER_SUMMARY"
}

format_rate_mib() {
  local bytes="$1" sec="$2"
  awk -v b="$bytes" -v s="$sec" 'BEGIN{if(s>0) printf "%.2f", b/1048576/s; else printf "0.00"}'
}

prepare_log() {
  mkdir -p "$LOG_DIR" || die 13 "Cannot create log directory: $LOG_DIR"
  RUN_LOG="${LOG_DIR}/write_$(date +%Y%m%d_%H%M%S).log"
}

write_tar_to_tape() {
  require_root
  need_cmd tar
  need_cmd mt
  collect_backup_dirs
  collect_source_metrics
  resolve_tape_device

  wait_tape_online || die 60 "Tape device is not ONLINE; load a cartridge first"
  rewind_tape
  prepare_log

  log "Preparing tape archive"
  log "Source NFS : $NFS_SOURCE"
  log "Source root: $NFS_MOUNT"
  log "Tape device: $RESOLVED_TAPE"
  log "Directories: ${BACKUP_DIRS[*]}"
  log "Source bytes: $SOURCE_BYTES"
  log "Ownership  : $SOURCE_OWNER_SUMMARY"
  log "Heartbeat  : ${HEARTBEAT_SEC}s"
  log "Write log  : $RUN_LOG"

  if (( DRY_RUN )); then
    run_cmd tar -cvf "$RESOLVED_TAPE" -C "$NFS_MOUNT" -- "${BACKUP_DIRS[@]}"
    return 0
  fi

  # Record source snapshot before writing for audit.
  {
    printf 'BEGIN %s\n' "$(ts)"
    printf 'NFS_SOURCE=%s\n' "$NFS_SOURCE"
    printf 'NFS_MOUNT=%s\n' "$NFS_MOUNT"
    printf 'TAPE_DEVICE=%s\n' "$RESOLVED_TAPE"
    printf 'SELECTED_TAPE=%s\n' "${SELECTED_TAPE:-UNKNOWN}"
    printf 'BACKUP_DIRS=%s\n' "${BACKUP_DIRS[*]}"
    printf 'SOURCE_BYTES=%s\n' "$SOURCE_BYTES"
    printf 'SOURCE_OWNERS=%s\n' "$SOURCE_OWNER_SUMMARY"
    printf 'HEARTBEAT_SEC=%s\n' "$HEARTBEAT_SEC"
    printf '%s\n' '--- TAR OUTPUT ---'
  } >>"$RUN_LOG"

  local rc tar_pid start_epoch now elapsed next_heartbeat
  start_epoch=$(date +%s)
  next_heartbeat=$HEARTBEAT_SEC
  set +e
  tar -cvf "$RESOLVED_TAPE" -C "$NFS_MOUNT" -- "${BACKUP_DIRS[@]}" >>"$RUN_LOG" 2>&1 &
  tar_pid=$!

  while kill -0 "$tar_pid" 2>/dev/null; do
    sleep 1
    now=$(date +%s)
    elapsed=$(( now - start_epoch ))
    if (( elapsed >= next_heartbeat )) && kill -0 "$tar_pid" 2>/dev/null; then
      log "[PROGRESS] phase=WRITE elapsed=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60))) source_dirs=${BACKUP_DIRS[*]} target=${SELECTED_TAPE:-UNKNOWN} device=$RESOLVED_TAPE tar_pid=$tar_pid state=RUNNING"
      next_heartbeat=$(( next_heartbeat + HEARTBEAT_SEC ))
    fi
  done


  wait "$tar_pid"
  rc=$?
  now=$(date +%s)
  WRITE_ELAPSED_SEC=$(( now - start_epoch ))
  WRITE_AVG_MIB="$(format_rate_mib "$SOURCE_BYTES" "$WRITE_ELAPSED_SEC")"

  printf 'TAR_RC=%s\nWRITE_ELAPSED_SEC=%s\nWRITE_AVG_MIB_PER_SEC=%s\nEND %s\n' \
    "$rc" "$WRITE_ELAPSED_SEC" "$WRITE_AVG_MIB" "$(ts)" >>"$RUN_LOG"
  if (( rc != 0 )); then
    err "tar write failed: rc=$rc device=$RESOLVED_TAPE elapsed=${WRITE_ELAPSED_SEC}s log=$RUN_LOG"
    err "Safety action: cartridge remains loaded for investigation; unload was NOT executed"
    exit 61
  fi

  ok "tar write completed successfully: device=$RESOLVED_TAPE bytes=$SOURCE_BYTES elapsed=${WRITE_ELAPSED_SEC}s avg=${WRITE_AVG_MIB}MiB/s log=$RUN_LOG"
}

verify_tape_none() {
  warn "Tape verification disabled (--verify none)"
}

verify_tape_probe() {
  need_cmd tar
  need_cmd mt
  need_cmd timeout
  resolve_tape_device
  rewind_tape

  local tmp rc
  tmp="$(mktemp /tmp/scalari3_tape_probe.XXXXXX)" || die 14 "mktemp failed"

  # A probe intentionally terminates tar after a small sample. The listing proves
  # that the archive header is readable; it is not a full-media verification.
  set +e
  timeout 90 tar -tvf "$RESOLVED_TAPE" >"$tmp" 2>&1 &
  local tpid=$!

  # Wait until enough lines are available, tar exits, or timeout is reached.
  local start lines=0
  start=$(date +%s)
  while kill -0 "$tpid" 2>/dev/null; do
    lines=$(wc -l <"$tmp" 2>/dev/null || echo 0)
    if (( lines >= PROBE_ENTRIES )); then
      kill "$tpid" 2>/dev/null || true
      wait "$tpid" 2>/dev/null
      break
    fi
    if (( $(date +%s) - start >= 90 )); then
      break
    fi
    sleep 1
  done
  wait "$tpid" 2>/dev/null
  rc=$?
  
  lines=$(wc -l <"$tmp" 2>/dev/null || echo 0)
  if (( lines == 0 )); then
    cat "$tmp" >&2
    rm -f "$tmp"
    rewind_tape
    die 70 "Tape probe could not read any tar entries"
  fi

  local displayed
  displayed=$(head -n "$PROBE_ENTRIES" "$tmp" | wc -l)
  printf '%s\n' '--- TAPE VERIFY SAMPLE ---' >&2
  head -n "$PROBE_ENTRIES" "$tmp" >&2
  printf '%s\n' '--- END VERIFY SAMPLE ---' >&2
  rm -f "$tmp"

  # rc may reflect SIGTERM/SIGPIPE because this is deliberately a short probe.
  rewind_tape
  ok "Tape probe verification PASSED: requested=$PROBE_ENTRIES displayed=$displayed (sample verification only)"
}

verify_tape_full() {
  need_cmd tar
  resolve_tape_device
  rewind_tape

  local verifylog rc entries
  verifylog="${LOG_DIR}/verify_$(date +%Y%m%d_%H%M%S).list"
  log "Performing FULL tape archive verification; this reads the entire archive"
  set +e
  tar -tf "$RESOLVED_TAPE" >"$verifylog" 2>&1
  rc=$?
  (( rc == 0 )) || {
    rewind_tape || true
    die 71 "Full tape verification failed: rc=$rc log=$verifylog"
  }
  entries=$(wc -l <"$verifylog")
  rewind_tape
  ok "Full tape verification PASSED: entries=$entries log=$verifylog"
}

verify_tape() {
  if (( DRY_RUN )); then
    log "DRY-RUN: skipping tape verification mode=$VERIFY_MODE"
    return 0
  fi
  case "$VERIFY_MODE" in
    none)  verify_tape_none ;;
    probe) verify_tape_probe ;;
    full)  verify_tape_full ;;
    *) die 15 "Invalid verify mode: $VERIFY_MODE (expected none|probe|full)" ;;
  esac
}

show_precheck_summary() {
  local load_action="BLOCKED"
  [[ "$DRIVE_MEDIA_STATE" == "EMPTY" ]] && load_action="ALLOWED"

  printf '\n' >&2
  printf '%s\n' '============================================================' >&2
  printf '%s\n' ' Scalar i3 Tape Write Pre-check' >&2
  printf '%s\n' '============================================================' >&2
  printf ' NFS Source      : %s\n' "$NFS_SOURCE" >&2
  printf ' NFS Mount       : %s\n' "$NFS_MOUNT" >&2
  printf ' Source Dirs     : %s\n' "${BACKUP_DIRS[*]:-not collected}" >&2
  printf ' Tape Link       : %s\n' "$TAPE_LINK" >&2
  printf ' Resolved Device : %s\n' "${RESOLVED_TAPE:-UNKNOWN}" >&2
  printf ' Drive State     : %s\n' "$DRIVE_MEDIA_STATE" >&2
  printf ' mt Status RC    : %s\n' "$DRIVE_STATUS_RC" >&2
  printf ' Robotics Load   : %s\n' "$load_action" >&2
  printf ' Verify Mode     : %s\n' "$VERIFY_MODE" >&2
  printf '%s\n' '============================================================' >&2
}

show_summary() {
  printf '\n' >&2
  printf '%s\n' '============================================================' >&2
  printf '%s\n' ' Scalar i3 Tape Write Summary' >&2
  printf '%s\n' '============================================================' >&2
  printf ' Selected Tape   : %s\n' "${SELECTED_TAPE:-UNKNOWN}" >&2
  printf ' Tape Device     : %s -> %s\n' "$TAPE_LINK" "${RESOLVED_TAPE:-UNKNOWN}" >&2
  printf ' NFS Source      : %s\n' "$NFS_SOURCE" >&2
  printf ' NFS Mount       : %s\n' "$NFS_MOUNT" >&2
  printf ' Source Dirs     : %s\n' "${BACKUP_DIRS[*]:-not collected}" >&2
  printf ' Verify Mode     : %s\n' "$VERIFY_MODE" >&2
  printf ' Source Bytes    : %s\n' "${SOURCE_BYTES:-0}" >&2
  printf ' Source Owners   : %s\n' "${SOURCE_OWNER_SUMMARY:-UNKNOWN}" >&2
  printf ' Write Elapsed   : %ss\n' "${WRITE_ELAPSED_SEC:-0}" >&2
  printf ' Avg Throughput  : %s MiB/s\n' "${WRITE_AVG_MIB:-0}" >&2
  printf ' Write Log       : %s\n' "${RUN_LOG:-N/A}" >&2
  printf '%s\n' '============================================================' >&2
}

enforce_prechecked_empty() {
  case "$DRIVE_MEDIA_STATE" in
    EMPTY)
      ok "Pre-check PASSED: drive is explicitly empty; robotics load is allowed"
      ;;
    LOADED)
      err "Pre-check BLOCKED: $RESOLVED_TAPE already contains media"
      printf '%s\n' "$DRIVE_STATUS_OUTPUT" >&2
      err "Scalar i3 load_tape was NOT executed"
      die 45 "Unload the existing cartridge first, then retry"
      ;;
    *)
      err "Pre-check BLOCKED: unable to prove that $RESOLVED_TAPE is empty"
      printf '%s\n' "$DRIVE_STATUS_OUTPUT" >&2
      err "Scalar i3 load_tape was NOT executed"
      die 46 "Expected an explicit empty/no-media state such as DR_OPEN; mt_rc=$DRIVE_STATUS_RC"
      ;;
  esac
}

precheck_run() {
  require_root
  collect_backup_dirs
  probe_drive_media_state
  show_precheck_summary
  enforce_prechecked_empty
}

load_command() {
  require_root
  probe_drive_media_state
  # load does not require an NFS scan, but always resolves the device and shows
  # the real media state before any robotics action.
  show_precheck_summary
  enforce_prechecked_empty

  # api_load intentionally repeats the empty-drive check immediately before
  # calling the robotics backend. This closes the race between display and load.
  api_load

  probe_drive_media_state
  if [[ "$DRIVE_MEDIA_STATE" == "LOADED" ]]; then
    ok "Post-load verification: $RESOLVED_TAPE is ONLINE/LOADED"
  else
    die 51 "Post-load verification failed: expected LOADED, actual=$DRIVE_MEDIA_STATE"
  fi
  show_summary
}

production_run() {
  require_root
  collect_backup_dirs

  # Resolve the tape symlink and determine the actual media state BEFORE
  # printing the summary. This avoids UNKNOWN device/state in production logs.
  probe_drive_media_state
  show_precheck_summary
  enforce_prechecked_empty

  # api_load performs the safety precheck again immediately before robotics.
  api_load

  # Refresh state after robotics load and print an accurate loaded summary.
  probe_drive_media_state
  [[ "$DRIVE_MEDIA_STATE" == "LOADED" ]] || die 51 "Post-load verification failed: expected LOADED, actual=$DRIVE_MEDIA_STATE"
  show_summary

  write_tar_to_tape
  verify_tape

  if (( KEEP_LOADED )); then
    ok "Backup completed successfully; cartridge left loaded by --keep"
  else
    api_unload
    ok "Backup completed successfully and cartridge unloaded"
  fi

  show_summary
}

acquire_lock() {
  need_cmd flock
  mkdir -p "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
  exec 9>"$LOCK_FILE" || die 16 "Cannot open lock file: $LOCK_FILE"
  flock -n 9 || die 17 "Another Scalar i3 tape-write operation is already running: $LOCK_FILE"
}

# ----------------------------- Arguments --------------------------------
COMMAND=""
while (( $# > 0 )); do
  case "$1" in
    scan|nfs-status|tape-status|drive-empty|precheck|load|write|unload|run)
      [[ -z "$COMMAND" ]] || die 2 "Only one command may be specified"
      COMMAND="$1"
      shift
      ;;
    --api-bin)
      [[ $# -ge 2 ]] || die 2 "--api-bin requires a value"
      API_BIN="$2"; shift 2
      ;;
    --nfs-source)
      [[ $# -ge 2 ]] || die 2 "--nfs-source requires a value"
      NFS_SOURCE="$2"; shift 2
      ;;
    --nfs-mount)
      [[ $# -ge 2 ]] || die 2 "--nfs-mount requires a value"
      NFS_MOUNT="$2"; shift 2
      ;;
    --tape-device)
      [[ $# -ge 2 ]] || die 2 "--tape-device requires a value"
      TAPE_LINK="$2"; shift 2
      ;;
    --pattern)
      [[ $# -ge 2 ]] || die 2 "--pattern requires a value"
      DIR_PATTERN="$2"; shift 2
      ;;
    --verify)
      [[ $# -ge 2 ]] || die 2 "--verify requires a value"
      VERIFY_MODE="$2"; shift 2
      ;;
    --probe-entries)
      [[ $# -ge 2 ]] || die 2 "--probe-entries requires a value"
      PROBE_ENTRIES="$2"; shift 2
      [[ "$PROBE_ENTRIES" =~ ^[1-9][0-9]*$ ]] || die 2 "--probe-entries must be a positive integer"
      ;;
    --heartbeat-sec)
      [[ $# -ge 2 ]] || die 2 "--heartbeat-sec requires a value"
      HEARTBEAT_SEC="$2"; shift 2
      [[ "$HEARTBEAT_SEC" =~ ^[1-9][0-9]*$ ]] || die 2 "--heartbeat-sec must be a positive integer"
      (( HEARTBEAT_SEC >= 5 && HEARTBEAT_SEC <= 3600 )) || die 2 "--heartbeat-sec must be between 5 and 3600"
      ;;
    --keep)
      KEEP_LOADED=1; shift
      ;;
    --dry-run)
      DRY_RUN=1; shift
      ;;
    --version)
      echo "$VERSION"; exit 0
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die 2 "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage; exit 2; }

case "$VERIFY_MODE" in none|probe|full) ;; *) die 2 "Invalid --verify mode: $VERIFY_MODE" ;; esac

# Commands that mutate tape/library state are serialized.
case "$COMMAND" in
  precheck|load|write|unload|run) acquire_lock ;;
esac

case "$COMMAND" in
  scan)
    print_backup_dirs
    ;;
  nfs-status)
    verify_nfs
    ;;
  tape-status)
    show_tape_status
    ;;
  drive-empty)
    show_drive_empty
    ;;
  precheck)
    precheck_run
    ;;
  load)
    load_command
    ;;
  write)
    write_tar_to_tape
    verify_tape
    show_summary
    ;;
  unload)
    api_unload
    ;;
  run)
    production_run
    ;;
esac
