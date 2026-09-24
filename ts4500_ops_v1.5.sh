#!/usr/bin/env bash
# ts4500_ops_v1.5.sh
# Production-style wrapper for IBM TS4500CLI.jar operations demonstrated in
# the user's environment.
#
# Supported workflow:
#   1. Verify target drive is ONLINE + EMPTY + Contents=Empty + library matches.
#   2. Select an eligible cartridge in Slot(...) for the logical library using
#      least-recently-used (oldest "Most Recent use") by default.
#   3. Move the cartridge to the target drive.
#   4. Poll until drive is ONLINE + READY and contains the expected cartridge,
#      then cross-check cartridge inventory says Drive(target...).
#   5. Unload from drive, poll until EMPTY, and verify the cartridge returned
#      to a normal Slot(...).
#   6. Optional EXPORT moves a cartridge from its slot to an I/O Slot using
#      --removeDataCartridges. This is deliberately separate from UNLOAD.
#   7. TAPE-PROBE validates the loaded tape is a readable tar archive, shows a
#      small sample of entries, and always rewinds to BOT afterward.
#   8. TAPE-READ verifies the loaded VOLSER, OS tape device, and expected NFS
#      mount, then extracts a tar archive from tape directly to NFS. NFS-safe
#      extraction uses tar --no-same-owner by default to tolerate root_squash.
#   9. RECOVER orchestrates a production recovery flow: load/reuse media,
#      probe, rewind, extract to NFS, verify recovered output, then keep,
#      unload, or unload+export to I/O slot.
#
# Security note:
# TS4500CLI.jar requires -p <password> in the demonstrated syntax. This script
# avoids hard-coding that password, but the Java process argument list may still
# expose it briefly to privileged local users while a CLI command runs.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME=${0##*/}
VERSION="1.5"

# ----------------------------- Defaults ------------------------------------
TS4500_JAR="${TS4500_JAR:-/aprun/shell/TS4500CLI.jar}"
TS4500_IP="${TS4500_IP:-192.168.175.100}"
TS4500_USER="${TS4500_USER:-admin}"
TS4500_PASSWORD_FILE="${TS4500_PASSWORD_FILE:-/root/.config/ts4500/password}"

TS4500_LIBRARY="${TS4500_LIBRARY:-Test}"
TS4500_FRAME="${TS4500_FRAME:-1}"
TS4500_COLUMN="${TS4500_COLUMN:-3}"
TS4500_ROW="${TS4500_ROW:-3}"

SELECTION_POLICY="${SELECTION_POLICY:-oldest}"  # oldest=LRU, newest=MRU, legacy-text=reproduce old sort
QUERY_TIMEOUT="${QUERY_TIMEOUT:-60}"
MOVE_TIMEOUT="${MOVE_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"
LOCK_FILE="${LOCK_FILE:-/var/lock/ts4500_ops.lock}"
LOCK_WAIT="${LOCK_WAIT:-10}"
STATE_FILE="${STATE_FILE:-/var/lib/ts4500_ops/last_unloaded.state}"

# OS tape/NFS recovery defaults. These can be overridden by environment or
# global CLI options. TAPE_DEVICE is expected to map to the configured TS4500
# physical drive F/C/R.
TAPE_DEVICE="${TAPE_DEVICE:-/dev/IBMtape0}"
NFS_SOURCE="${NFS_SOURCE:-192.168.167.214:/tapedir}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/tmp}"
TAPE_READ_LOG_DIR="${TAPE_READ_LOG_DIR:-/var/log/ts4500_ops}"
TAPE_PROBE_ENTRIES="${TAPE_PROBE_ENTRIES:-10}"
TAPE_PROBE_TIMEOUT="${TAPE_PROBE_TIMEOUT:-60}"

DRY_RUN=0
QUIET=0
LOCK_HELD=0

# Exit codes
RC_USAGE=2
RC_DEPENDENCY=3
RC_AUTH=4
RC_CLI=10
RC_NOT_FOUND=11
RC_DRIVE_NOT_AVAILABLE=20
RC_DRIVE_NOT_READY=21
RC_CARTRIDGE_NOT_ELIGIBLE=30
RC_NO_CANDIDATE=31
RC_VERIFY=40
RC_TIMEOUT=41
RC_LOCK=50
RC_TAPE_DEVICE=60
RC_NFS=61
RC_TAR=62
RC_PROBE=63
RC_RECOVERY=64

TS4500_PASSWORD="${TS4500_PASSWORD:-}"

# ----------------------------- Helpers -------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }

info() {
  (( QUIET )) || printf '%s [INFO] %s\n' "$(ts)" "$*" >&2
}

warn() {
  printf '%s [WARN] %s\n' "$(ts)" "$*" >&2
}

err() {
  printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2
}

fail() {
  local rc=$1
  shift
  err "$*"
  exit "$rc"
}

usage() {
  cat <<'USAGE'
Usage:
  ts4500_ops_v1.5.sh [GLOBAL OPTIONS] COMMAND [COMMAND ARGS]

Global options:
  --ip IP                 TS4500 management IP
  --user USER             TS4500 CLI username
  --password-file FILE    Root-readable file containing only the password
  --jar FILE              Path to TS4500CLI.jar
  --library NAME          Logical Library (default: Test)
  --frame N               Target drive frame (default: 1)
  --column N              Target drive column (default: 3)
  --row N                 Target drive row (default: 3)
  --policy oldest|newest|legacy-text
                          Selection policy (default: oldest / true chronological LRU)
  --query-timeout SEC     Timeout for inventory queries (default: 60)
  --move-timeout SEC      Timeout for robotic move commands (default: 180)
  --verify-timeout SEC    Post-move verification timeout (default: 120)
  --poll SEC              Poll interval (default: 2)
  --lock-file FILE        Lock file for mutating operations
  --state-file FILE       Persistent latest-unloaded VOLSER/Slot state
                         (default: /var/lib/ts4500_ops/last_unloaded.state)
  --tape-device DEV        OS tape device (default: /dev/IBMtape0)
  --nfs-source SOURCE      Expected NFS source
                         (default: 192.168.167.214:/tapedir)
  --nfs-mount DIR          Expected NFS mount point (default: /mnt/tmp)
  --read-log-dir DIR       Tape extraction/probe log directory
                         (default: /var/log/ts4500_ops)
  --probe-entries N         tape-probe sample entries (default: 10)
  --probe-timeout SEC       Maximum tape-probe read time (default: 60)
  --dry-run                Validate/print intended move but do not move media
  --quiet                  Reduce informational output
  -h, --help               Show help
  -V, --version            Show version

Commands:
  status
      Show the target drive and eligible cartridge candidates.

  drive-check
      Verify target drive is available for loading:
        State=ONLINE, Operation=EMPTY, Contents=Empty,
        Logical Library=<configured library>.

  candidates
      List eligible cartridges for the configured logical library.
      Only Location=Slot(...) is accepted; Drive(...) and I/O Slot(...) are
      excluded. Rows are ordered according to --policy. legacy-text reproduces
      a plain string sort of MM/DD/YYYY and is kept only for compatibility.

  select
      Print only the selected Volume Serial. Default policy is oldest/LRU.

  load [VOLSER]
      If VOLSER is omitted, select one automatically. Re-check drive and media,
      move cartridge to target drive, then verify both drive and inventory.

  verify-loaded VOLSER
      Verify target drive is ONLINE + READY, contains VOLSER, belongs to the
      configured logical library, and inventory says Drive(target...).

  unload [VOLSER]
      Unload the target drive. If VOLSER is omitted, automatically detect it
      from the configured drive Contents field. After unload, verify the drive
      returns to EMPTY, detect the exact returned Slot(...), and atomically save
      VOLSER + Slot + library + drive identity in --state-file.

  last-unloaded
      Show the remembered latest successfully unloaded VOLSER and exact Slot.

  export [VOLSER] --yes
      Move a cartridge from a normal Slot(...) to an I/O Slot using
      --removeDataCartridges. If VOLSER is omitted (example: export --yes), use
      the remembered latest-unloaded VOLSER. Before moving, verify the cartridge
      is STILL in the remembered exact Slot and configured logical library.

  unload-export [VOLSER] --yes
      One-shot workflow: auto-detect/verify the loaded VOLSER, unload it, remember
      its exact returned Slot, then export THAT SAME cartridge to an I/O Slot.

  tape-status [VOLSER]
      Verify TS4500 reports the target drive ONLINE + READY with media loaded,
      optionally require the expected VOLSER, validate /dev/IBMtape0 (or
      --tape-device), and show the OS tape-device status.

  tape-probe [VOLSER] [--entries N] [--timeout SEC]
      Validate the loaded tape can be read as a tar archive. The command rewinds
      to BOT, lists a small sample of archive entries, and ALWAYS attempts a
      final rewind so the next read begins at BOT. It does not require NFS.

  tape-read [VOLSER] [--to DIR] [--allow-existing] [--no-rewind] [--preserve-owner]
      Extract a tar archive from the loaded tape to NFS. If VOLSER is omitted,
      detect it from the target drive Contents field. Before reading, require:
        * TS4500 target drive ONLINE + READY with that VOLSER
        * cartridge inventory at Drive(target...)
        * tape device exists, is a character device, and is not in use
        * --nfs-mount is mounted from exactly --nfs-source as nfs/nfs4
        * destination is on/under --nfs-mount and writable
      Default destination: <nfs-mount>/<VOLSER>
      Default behavior rewinds the tape before tar extraction.
      --allow-existing permits extraction into a non-empty destination and may
      overwrite colliding paths. --no-rewind skips the explicit pre-read rewind.
      NFS-safe default: tar --no-same-owner, so root_squash does not turn valid
      data recovery into rc=2 merely because archived UID/GID cannot be chowned.
      --preserve-owner requests original tar ownership restoration; use only when
      the NFS server/export permits chown of archived UID/GID values.

  recover [VOLSER] [--to DIR] [--allow-existing] [--preserve-owner]
          [--probe-entries N] [--probe-timeout SEC]
          [--after keep|unload|export] [--yes]
      Production recovery flow. If the drive is EMPTY, load VOLSER or auto-select
      one. If it is already READY, reuse the currently loaded cartridge (and
      enforce VOLSER if supplied). Then:
        TS4500 verify -> OS tape verify -> tape-probe -> rewind -> tar restore
        -> recovered-output verification -> post-read TS4500 verification.
      Restore ownership defaults to NFS-safe --no-same-owner.
      --preserve-owner requests archived UID/GID restoration and may fail on
      root_squash NFS exports.
      --after keep     leave tape mounted after success.
      --after unload   unload to its normal Slot after success (default).
      --after export   unload, remember exact Slot, then export same VOLSER to
                       I/O Slot; requires --yes.
      A probe/restore/verification failure NEVER auto-unloads or exports media.

  test-cycle [VOLSER]
      Mechanical test: load and verify, then immediately unload and verify.
      If VOLSER is omitted, one is selected using --policy.

  drive-summary
      Print raw --viewDriveSummary output.

  cartridges
      Print raw --viewDataCartridges output.

Credential setup example:
  install -d -m 700 /root/.config/ts4500
  printf '%s\n' 'YOUR_PASSWORD' > /root/.config/ts4500/password
  chmod 600 /root/.config/ts4500/password

Examples:
  ./ts4500_ops_v1.5.sh drive-check
  ./ts4500_ops_v1.5.sh candidates
  VOL=$(./ts4500_ops_v1.5.sh select)
  ./ts4500_ops_v1.5.sh load "$VOL"
  ./ts4500_ops_v1.5.sh verify-loaded "$VOL"
  ./ts4500_ops_v1.5.sh tape-status
  ./ts4500_ops_v1.5.sh tape-probe
  ./ts4500_ops_v1.5.sh tape-probe "$VOL" --entries 10
  ./ts4500_ops_v1.5.sh tape-read          # NFS-safe: --no-same-owner by default
  ./ts4500_ops_v1.5.sh recover --after unload
  ./ts4500_ops_v1.5.sh recover "$VOL" --after export --yes
  ./ts4500_ops_v1.5.sh unload             # auto-detect VOLSER and remember returned Slot
  ./ts4500_ops_v1.5.sh last-unloaded
  ./ts4500_ops_v1.5.sh export --yes       # export remembered VOLSER from remembered Slot
  ./ts4500_ops_v1.5.sh export "$VOL" --yes
  ./ts4500_ops_v1.5.sh unload-export --yes # unload + remember + export same tape
USAGE
}

require_uint() {
  local name=$1 value=$2
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$RC_USAGE" "$name must be an integer: $value"
}

validate_settings() {
  require_uint frame "$TS4500_FRAME"
  require_uint column "$TS4500_COLUMN"
  require_uint row "$TS4500_ROW"
  require_uint query-timeout "$QUERY_TIMEOUT"
  require_uint move-timeout "$MOVE_TIMEOUT"
  require_uint verify-timeout "$VERIFY_TIMEOUT"
  require_uint poll "$POLL_INTERVAL"
  require_uint lock-wait "$LOCK_WAIT"
  require_uint probe-entries "$TAPE_PROBE_ENTRIES"
  require_uint probe-timeout "$TAPE_PROBE_TIMEOUT"
  (( TAPE_PROBE_ENTRIES >= 1 )) || fail "$RC_USAGE" "probe-entries must be >= 1"
  (( TAPE_PROBE_TIMEOUT >= 1 )) || fail "$RC_USAGE" "probe-timeout must be >= 1"

  case "$SELECTION_POLICY" in
    oldest|newest|legacy-text) ;;
    *) fail "$RC_USAGE" "--policy must be oldest, newest, or legacy-text" ;;
  esac

  [[ -n "$TS4500_IP" ]] || fail "$RC_USAGE" "TS4500 IP is empty"
  [[ -n "$TS4500_USER" ]] || fail "$RC_USAGE" "TS4500 user is empty"
  [[ -n "$TS4500_LIBRARY" ]] || fail "$RC_USAGE" "Logical Library is empty"
  [[ -r "$TS4500_JAR" ]] || fail "$RC_DEPENDENCY" "JAR not readable: $TS4500_JAR"
  command -v java >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "java not found in PATH"
  command -v timeout >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "timeout not found in PATH"
  command -v awk >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "awk not found in PATH"
  command -v sort >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "sort not found in PATH"
}

load_password() {
  if [[ -n "$TS4500_PASSWORD" ]]; then
    return 0
  fi

  [[ -r "$TS4500_PASSWORD_FILE" ]] || \
    fail "$RC_AUTH" "Password not supplied. Set TS4500_PASSWORD or create $TS4500_PASSWORD_FILE"

  TS4500_PASSWORD=$(head -n 1 -- "$TS4500_PASSWORD_FILE" || true)
  [[ -n "$TS4500_PASSWORD" ]] || fail "$RC_AUTH" "Password file is empty: $TS4500_PASSWORD_FILE"

  # Warn when the file is group/world accessible. Do not fail because some
  # enterprise filesystems may present non-standard modes.
  if command -v stat >/dev/null 2>&1; then
    local mode
    mode=$(stat -c '%a' -- "$TS4500_PASSWORD_FILE" 2>/dev/null || true)
    if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
      local last3=${mode: -3}
      local g=${last3:1:1} o=${last3:2:1}
      if (( g != 0 || o != 0 )); then
        warn "Password file permissions are broader than 0600: mode=$mode file=$TS4500_PASSWORD_FILE"
      fi
    fi
  fi
}

run_cli() {
  local timeout_sec=$1
  shift
  local out rc

  load_password

  set +e
  out=$(timeout --signal=TERM --kill-after=5 "${timeout_sec}s" \
      java -jar "$TS4500_JAR" \
      -ip "$TS4500_IP" \
      -u "$TS4500_USER" \
      -p "$TS4500_PASSWORD" \
      "$@" 2>&1)
  rc=$?
  set -e

  if (( rc == 124 || rc == 137 )); then
    err "TS4500CLI timeout after ${timeout_sec}s: $*"
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    return "$RC_TIMEOUT"
  fi

  if (( rc != 0 )); then
    err "TS4500CLI exited rc=$rc: $*"
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    return "$RC_CLI"
  fi

  if grep -Eqi '^\*{4}ERROR:|problem in the command execution|exception"[[:space:]]*:' <<<"$out"; then
    err "TS4500CLI reported an application error: $*"
    printf '%s\n' "$out" >&2
    return "$RC_CLI"
  fi

  printf '%s\n' "$out"
}

view_drive_summary() {
  run_cli "$QUERY_TIMEOUT" --viewDriveSummary
}

view_cartridges() {
  run_cli "$QUERY_TIMEOUT" --viewDataCartridges
}

# Output fields:
# state|operation|contents|logical_library|type|serial|wwnn|element
get_target_drive() {
  local raw=${1:-}
  [[ -n "$raw" ]] || raw=$(view_drive_summary) || return $?

  awk -F',' \
      -v f="F${TS4500_FRAME}" \
      -v c="C${TS4500_COLUMN}" \
      -v r="R${TS4500_ROW}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      for (i=1; i<=NF; i++) $i=trim($i)
      if ($1==f && $2==c && $3==r) {
        printf "%s|%s|%s|%s|%s|%s|%s|%s\n", $4,$5,$7,$12,$6,$9,$10,$11
        found=1
        exit
      }
    }
    END { if (!found) exit 11 }
  ' <<<"$raw"
}

# Output fields:
# volume|logical_library|element|media|location|encryption|last_use
get_cartridge() {
  local vol=$1
  local raw=${2:-}
  [[ -n "$raw" ]] || raw=$(view_cartridges) || return $?

  awk -F',' -v want="$vol" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      for (i=1; i<=NF; i++) $i=trim($i)
      if ($1==want) {
        loc=$5 "," $6 "," $7 "," $8
        printf "%s|%s|%s|%s|%s|%s|%s\n", $1,$2,$3,$4,loc,$9,$10
        found=1
        exit
      }
    }
    END { if (!found) exit 11 }
  ' <<<"$raw"
}

# Produces sortable rows:
# YYYYMMDDHHMMSS|VOLSER|MM/DD/YYYY HH:MM:SS|Slot(...)
# Invalid or unrecognized timestamps are intentionally excluded from automatic
# selection to avoid choosing media based on ambiguous metadata.
candidate_rows() {
  local raw=${1:-}
  [[ -n "$raw" ]] || raw=$(view_cartridges) || return $?

  awk -F',' -v lib="$TS4500_LIBRARY" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      for (i=1; i<=NF; i++) $i=trim($i)
      loc=$5 "," $6 "," $7 "," $8

      # Exact logical library match, and only normal storage slots.
      if ($2 != lib || loc !~ /^Slot\(/) next

      # Expected format seen in TS4500CLI output: MM/DD/YYYY HH:MM:SS
      if ($10 !~ /^[0-9][0-9]?\/[0-9][0-9]?\/[0-9][0-9][0-9][0-9][[:space:]][0-9][0-9]?:[0-9][0-9]:[0-9][0-9]$/) next

      n=split($10, p, /[\/:[:space:]]+/)
      if (n < 6) next
      key=sprintf("%04d%02d%02d%02d%02d%02d", p[3],p[1],p[2],p[4],p[5],p[6])
      printf "%s|%s|%s|%s\n", key,$1,$10,loc
    }
  ' <<<"$raw"
}

ordered_candidates() {
  local rows
  rows=$(candidate_rows) || return $?
  [[ -n "$rows" ]] || return "$RC_NO_CANDIDATE"

  case "$SELECTION_POLICY" in
    oldest)
      sort -t'|' -k1,1 -k2,2 <<<"$rows"
      ;;
    newest)
      sort -t'|' -k1,1r -k2,2 <<<"$rows"
      ;;
    legacy-text)
      # Compatibility with the original pipeline that sorts the displayed
      # MM/DD/YYYY timestamp as text. This is NOT chronological across years.
      sort -t'|' -k3,3 -k2,2 <<<"$rows"
      ;;
  esac
}

select_volume() {
  local first
  first=$(ordered_candidates | head -n 1) || true
  [[ -n "$first" ]] || return "$RC_NO_CANDIDATE"
  IFS='|' read -r _key vol _last _loc <<<"$first"
  printf '%s\n' "$vol"
}

print_target_drive() {
  local d state op contents lib type serial wwnn elem
  d=$(get_target_drive) || return $?
  IFS='|' read -r state op contents lib type serial wwnn elem <<<"$d"
  printf 'Target Drive : F%s C%s R%s\n' "$TS4500_FRAME" "$TS4500_COLUMN" "$TS4500_ROW"
  printf 'State        : %s\n' "$state"
  printf 'Operation    : %s\n' "$op"
  printf 'Contents     : %s\n' "$contents"
  printf 'Library      : %s\n' "$lib"
  printf 'Type         : %s\n' "$type"
  printf 'Serial       : %s\n' "$serial"
  printf 'WWNN         : %s\n' "$wwnn"
  printf 'Element Addr : %s\n' "$elem"
}

drive_check_available() {
  local d state op contents lib _rest
  d=$(get_target_drive) || fail "$RC_NOT_FOUND" \
    "Target drive F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW} not found"

  IFS='|' read -r state op contents lib _rest <<<"$d"

  [[ "$lib" == "$TS4500_LIBRARY" ]] || fail "$RC_DRIVE_NOT_AVAILABLE" \
    "Drive logical library mismatch: expected='$TS4500_LIBRARY' actual='$lib'"
  [[ "${state^^}" == "ONLINE" ]] || fail "$RC_DRIVE_NOT_AVAILABLE" \
    "Drive is not ONLINE: state='$state'"
  [[ "${op^^}" == "EMPTY" ]] || fail "$RC_DRIVE_NOT_AVAILABLE" \
    "Drive is not EMPTY: operation='$op' contents='$contents'"
  [[ "${contents^^}" == "EMPTY" ]] || fail "$RC_DRIVE_NOT_AVAILABLE" \
    "Drive contents is not Empty: contents='$contents' operation='$op'"

  info "Drive F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW} is available: ONLINE / EMPTY / Empty / library=$TS4500_LIBRARY"
}

verify_cartridge_eligible() {
  local want=$1
  local row vol lib _elem _media loc _enc _last
  row=$(get_cartridge "$want") || fail "$RC_NOT_FOUND" "Cartridge not found: $want"
  IFS='|' read -r vol lib _elem _media loc _enc _last <<<"$row"

  [[ "$lib" == "$TS4500_LIBRARY" ]] || fail "$RC_CARTRIDGE_NOT_ELIGIBLE" \
    "Cartridge $want logical library mismatch: expected='$TS4500_LIBRARY' actual='$lib'"
  [[ "$loc" == Slot\(* ]] || fail "$RC_CARTRIDGE_NOT_ELIGIBLE" \
    "Cartridge $want is not in a normal Slot: location='$loc'"

  info "Cartridge eligible: volume=$want library=$lib location=$loc"
}

is_failure_operation() {
  local op=${1^^}
  [[ "$op" == *FAIL* || "$op" == *ERROR* || "$op" == *FAULT* ]]
}

wait_drive_loaded() {
  local want=$1
  local start=$SECONDS d state op contents lib _rest

  while (( SECONDS - start <= VERIFY_TIMEOUT )); do
    d=$(get_target_drive 2>/dev/null || true)
    if [[ -n "$d" ]]; then
      IFS='|' read -r state op contents lib _rest <<<"$d"

      if is_failure_operation "$op"; then
        err "Drive entered failure operation state: operation='$op'"
        return "$RC_VERIFY"
      fi

      if [[ "${state^^}" == "ONLINE" && "${op^^}" == "READY" && "$contents" == "$want" && "$lib" == "$TS4500_LIBRARY" ]]; then
        return 0
      fi
    fi
    sleep "$POLL_INTERVAL"
  done

  err "Timed out waiting for drive READY with $want"
  return "$RC_TIMEOUT"
}

wait_drive_empty() {
  local start=$SECONDS d state op contents lib _rest

  while (( SECONDS - start <= VERIFY_TIMEOUT )); do
    d=$(get_target_drive 2>/dev/null || true)
    if [[ -n "$d" ]]; then
      IFS='|' read -r state op contents lib _rest <<<"$d"

      if is_failure_operation "$op"; then
        err "Drive entered failure operation state: operation='$op'"
        return "$RC_VERIFY"
      fi

      if [[ "${state^^}" == "ONLINE" && "${op^^}" == "EMPTY" && "${contents^^}" == "EMPTY" && "$lib" == "$TS4500_LIBRARY" ]]; then
        return 0
      fi
    fi
    sleep "$POLL_INTERVAL"
  done

  err "Timed out waiting for drive EMPTY"
  return "$RC_TIMEOUT"
}

wait_cartridge_location() {
  local want=$1 mode=$2
  local start=$SECONDS row vol lib _elem _media loc _enc _last
  local drive_prefix="Drive(F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW},"

  while (( SECONDS - start <= VERIFY_TIMEOUT )); do
    row=$(get_cartridge "$want" 2>/dev/null || true)
    if [[ -n "$row" ]]; then
      IFS='|' read -r vol lib _elem _media loc _enc _last <<<"$row"
      case "$mode" in
        drive)
          if [[ "$lib" == "$TS4500_LIBRARY" && "$loc" == "$drive_prefix"* ]]; then
            return 0
          fi
          ;;
        slot)
          if [[ "$lib" == "$TS4500_LIBRARY" && "$loc" == Slot\(* ]]; then
            return 0
          fi
          ;;
        io)
          if [[ "$lib" == "Available" && "$loc" == "I/O Slot("* ]]; then
            return 0
          fi
          ;;
        *)
          err "Internal error: unknown location wait mode '$mode'"
          return "$RC_USAGE"
          ;;
      esac
    fi
    sleep "$POLL_INTERVAL"
  done

  err "Timed out waiting for cartridge $want location mode=$mode"
  return "$RC_TIMEOUT"
}

# Return the exact current normal Slot(...) for a cartridge.
# Output: Slot(Fx,Cy,Rz,Tn)
get_cartridge_slot() {
  local want=$1
  local row vol lib _elem _media loc _enc _last
  row=$(get_cartridge "$want") || return $?
  IFS='|' read -r vol lib _elem _media loc _enc _last <<<"$row"
  [[ "$lib" == "$TS4500_LIBRARY" && "$loc" == Slot\(* ]] || return "$RC_VERIFY"
  printf '%s\n' "$loc"
}

remember_unloaded() {
  local vol=$1 slot=$2
  local dir tmp epoch
  dir=$(dirname -- "$STATE_FILE")
  mkdir -p -- "$dir" || fail "$RC_VERIFY" "Cannot create state directory: $dir"
  chmod 700 -- "$dir" 2>/dev/null || true

  epoch=$(date +%s)
  tmp="${STATE_FILE}.tmp.$$"

  # One pipe-delimited record; do not source/eval this file later.
  # epoch|volser|library|slot|frame|column|row
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$epoch" "$vol" "$TS4500_LIBRARY" "$slot" \
    "$TS4500_FRAME" "$TS4500_COLUMN" "$TS4500_ROW" > "$tmp" || {
      rm -f -- "$tmp"
      fail "$RC_VERIFY" "Cannot write state file: $STATE_FILE"
    }
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$STATE_FILE" || {
    rm -f -- "$tmp"
    fail "$RC_VERIFY" "Cannot install state file: $STATE_FILE"
  }

  info "Remembered latest unloaded cartridge: volume=$vol location=$slot state_file=$STATE_FILE"
}

# Output fields: epoch|vol|library|slot|frame|column|row
read_unloaded_state() {
  [[ -r "$STATE_FILE" ]] || return "$RC_NOT_FOUND"

  local line epoch vol lib slot f c r extra
  IFS= read -r line < "$STATE_FILE" || return "$RC_NOT_FOUND"
  IFS='|' read -r epoch vol lib slot f c r extra <<<"$line"

  [[ -z "${extra:-}" && "$epoch" =~ ^[0-9]+$ && -n "$vol" && -n "$lib" && \
     "$slot" == Slot\(* && "$f" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$r" =~ ^[0-9]+$ ]] || {
    err "Invalid latest-unloaded state file: $STATE_FILE"
    return "$RC_VERIFY"
  }

  printf '%s|%s|%s|%s|%s|%s|%s\n' "$epoch" "$vol" "$lib" "$slot" "$f" "$c" "$r"
}

verify_remembered_for_export() {
  local requested=${1:-}
  local st epoch vol lib slot f c r
  local row curvol curlib _elem _media curloc _enc _last

  st=$(read_unloaded_state) || return $?
  IFS='|' read -r epoch vol lib slot f c r <<<"$st"

  if [[ -n "$requested" && "$requested" != "$vol" ]]; then
    err "Remembered latest unloaded volume is '$vol', not requested '$requested'"
    return "$RC_VERIFY"
  fi
  [[ "$lib" == "$TS4500_LIBRARY" ]] || {
    err "Remembered library mismatch: saved='$lib' configured='$TS4500_LIBRARY'"
    return "$RC_VERIFY"
  }
  [[ "$f" == "$TS4500_FRAME" && "$c" == "$TS4500_COLUMN" && "$r" == "$TS4500_ROW" ]] || {
    err "Remembered drive mismatch: saved=F${f},C${c},R${r} configured=F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW}"
    return "$RC_VERIFY"
  }

  row=$(get_cartridge "$vol") || {
    err "Remembered cartridge no longer exists in current inventory: $vol"
    return "$RC_NOT_FOUND"
  }
  IFS='|' read -r curvol curlib _elem _media curloc _enc _last <<<"$row"

  [[ "$curlib" == "$TS4500_LIBRARY" ]] || {
    err "Refusing auto-export: $vol library changed: saved='$lib' current='$curlib'"
    return "$RC_VERIFY"
  }
  [[ "$curloc" == "$slot" ]] || {
    err "Refusing auto-export: $vol moved since unload: saved='$slot' current='$curloc'"
    return "$RC_VERIFY"
  }
  [[ "$curloc" == Slot\(* ]] || {
    err "Refusing auto-export: $vol is not in a normal Slot: '$curloc'"
    return "$RC_VERIFY"
  }

  printf '%s|%s\n' "$vol" "$slot"
}

clear_unloaded_state_if_volume() {
  local vol=$1 st _epoch saved _rest
  st=$(read_unloaded_state 2>/dev/null || true)
  [[ -n "$st" ]] || return 0
  IFS='|' read -r _epoch saved _rest <<<"$st"
  if [[ "$saved" == "$vol" ]]; then
    rm -f -- "$STATE_FILE" || warn "Could not remove stale state file after export: $STATE_FILE"
    info "Cleared latest-unloaded state after successful export: volume=$vol"
  fi
}

cmd_last_unloaded() {
  local st epoch vol lib slot f c r human
  st=$(read_unloaded_state) || fail "$RC_NOT_FOUND" "No remembered unloaded cartridge: $STATE_FILE"
  IFS='|' read -r epoch vol lib slot f c r <<<"$st"
  human=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$epoch")
  printf 'VOLSER       : %s\n' "$vol"
  printf 'Slot         : %s\n' "$slot"
  printf 'Library      : %s\n' "$lib"
  printf 'Source Drive : F%s C%s R%s\n' "$f" "$c" "$r"
  printf 'Remembered   : %s\n' "$human"
  printf 'State File   : %s\n' "$STATE_FILE"
}

verify_loaded() {
  local want=$1
  local d state op contents lib _rest

  d=$(get_target_drive) || fail "$RC_NOT_FOUND" "Target drive not found"
  IFS='|' read -r state op contents lib _rest <<<"$d"

  [[ "$lib" == "$TS4500_LIBRARY" ]] || fail "$RC_VERIFY" \
    "Loaded-drive library mismatch: expected='$TS4500_LIBRARY' actual='$lib'"
  [[ "${state^^}" == "ONLINE" ]] || fail "$RC_VERIFY" "Drive is not ONLINE: '$state'"
  [[ "${op^^}" == "READY" ]] || fail "$RC_DRIVE_NOT_READY" \
    "Drive is not READY: operation='$op' contents='$contents'"
  [[ "$contents" == "$want" ]] || fail "$RC_VERIFY" \
    "Drive contains '$contents', expected '$want'"
  is_failure_operation "$op" && fail "$RC_VERIFY" "Drive operation indicates failure: '$op'"

  wait_cartridge_location "$want" drive || exit $?
  info "Verified loaded: drive=F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW} volume=$want state=ONLINE operation=READY"
}

acquire_lock() {
  (( LOCK_HELD )) && return 0
  command -v flock >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "flock not found in PATH"
  mkdir -p -- "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
  exec 9>"$LOCK_FILE" || fail "$RC_LOCK" "Cannot open lock file: $LOCK_FILE"
  flock -w "$LOCK_WAIT" 9 || fail "$RC_LOCK" "Could not acquire lock within ${LOCK_WAIT}s: $LOCK_FILE"
  LOCK_HELD=1
}

move_to_drive() {
  local vol=$1 out
  if (( DRY_RUN )); then
    info "DRY-RUN: would execute --moveToDrive '$vol' -f${TS4500_FRAME} -c${TS4500_COLUMN} -r${TS4500_ROW}"
    return 0
  fi

  out=$(run_cli "$MOVE_TIMEOUT" --moveToDrive "$vol" \
      "-f${TS4500_FRAME}" "-c${TS4500_COLUMN}" "-r${TS4500_ROW}") || return $?
  printf '%s\n' "$out" >&2
}

move_from_drive() {
  local out
  if (( DRY_RUN )); then
    info "DRY-RUN: would execute --moveFromDrive -f${TS4500_FRAME} -c${TS4500_COLUMN} -r${TS4500_ROW}"
    return 0
  fi

  out=$(run_cli "$MOVE_TIMEOUT" --moveFromDrive \
      "-f${TS4500_FRAME}" "-c${TS4500_COLUMN}" "-r${TS4500_ROW}") || return $?
  printf '%s\n' "$out" >&2
}

remove_data_cartridge() {
  local vol=$1 out
  if (( DRY_RUN )); then
    info "DRY-RUN: would execute --removeDataCartridges '$vol'"
    return 0
  fi

  out=$(run_cli "$MOVE_TIMEOUT" --removeDataCartridges "$vol") || return $?
  printf '%s\n' "$out" >&2
}

cmd_status() {
  print_target_drive
  printf '\nEligible cartridges (%s first):\n' "$SELECTION_POLICY"
  printf '%-12s %-20s %s\n' 'VOLSER' 'MOST_RECENT_USE' 'LOCATION'
  local rows row key vol last loc
  rows=$(ordered_candidates 2>/dev/null || true)
  if [[ -z "$rows" ]]; then
    printf '%s\n' '(none)'
    return 0
  fi
  while IFS='|' read -r key vol last loc; do
    printf '%-12s %-20s %s\n' "$vol" "$last" "$loc"
  done <<<"$rows"
}

cmd_candidates() {
  local rows key vol last loc
  rows=$(ordered_candidates) || fail "$RC_NO_CANDIDATE" \
    "No eligible cartridges in library '$TS4500_LIBRARY' with Location=Slot(...) and a parseable Most Recent use timestamp"
  printf '%-12s %-20s %s\n' 'VOLSER' 'MOST_RECENT_USE' 'LOCATION'
  while IFS='|' read -r key vol last loc; do
    printf '%-12s %-20s %s\n' "$vol" "$last" "$loc"
  done <<<"$rows"
}

cmd_select() {
  local vol
  vol=$(select_volume) || fail "$RC_NO_CANDIDATE" \
    "No eligible cartridges in library '$TS4500_LIBRARY'"
  printf '%s\n' "$vol"
}

cmd_load() {
  local vol=${1:-}
  acquire_lock

  drive_check_available

  if [[ -z "$vol" ]]; then
    vol=$(select_volume) || fail "$RC_NO_CANDIDATE" \
      "No eligible cartridges in library '$TS4500_LIBRARY'"
    info "Auto-selected volume=$vol policy=$SELECTION_POLICY"
  fi

  verify_cartridge_eligible "$vol"

  # Re-check the drive immediately before issuing the robotic move.
  drive_check_available

  move_to_drive "$vol" || exit $?
  if (( DRY_RUN )); then
    return 0
  fi

  wait_drive_loaded "$vol" || exit $?
  verify_loaded "$vol"
  printf '%s\n' "$vol"
}

cmd_unload() {
  local vol=${1:-}
  local d state op contents lib _rest slot
  acquire_lock

  if [[ -z "$vol" ]]; then
    d=$(get_target_drive) || fail "$RC_NOT_FOUND" \
      "Target drive F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW} not found"
    IFS='|' read -r state op contents lib _rest <<<"$d"

    [[ "$lib" == "$TS4500_LIBRARY" ]] || fail "$RC_VERIFY" \
      "Drive logical library mismatch: expected='$TS4500_LIBRARY' actual='$lib'"
    [[ "${state^^}" == "ONLINE" ]] || fail "$RC_DRIVE_NOT_READY" \
      "Cannot auto-detect VOLSER: drive is not ONLINE: state='$state'"
    is_failure_operation "$op" && fail "$RC_VERIFY" \
      "Cannot auto-detect VOLSER: drive operation indicates failure: '$op'"
    [[ "${op^^}" == "READY" ]] || fail "$RC_DRIVE_NOT_READY" \
      "Cannot unload: drive is not READY: operation='$op' contents='$contents'"
    [[ -n "$contents" && "${contents^^}" != "EMPTY" ]] || fail "$RC_DRIVE_NOT_READY" \
      "Cannot unload: target drive is empty; no VOLSER to auto-detect"

    vol=$contents
    info "Auto-detected mounted volume=$vol from drive F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW}"
  fi

  verify_loaded "$vol"

  move_from_drive || exit $?
  if (( DRY_RUN )); then
    printf '%s\n' "$vol"
    return 0
  fi

  wait_drive_empty || exit $?
  wait_cartridge_location "$vol" slot || exit $?
  slot=$(get_cartridge_slot "$vol") || fail "$RC_VERIFY" \
    "Unload completed but exact returned Slot could not be determined for $vol"

  remember_unloaded "$vol" "$slot"
  info "Verified unloaded: drive EMPTY and volume=$vol returned to $slot in library=$TS4500_LIBRARY"
  printf '%s\n' "$vol"
}

cmd_export() {
  local vol=${1:-}
  local confirm=${2:-}
  local auto=0 remembered slot row curvol curlib _elem _media curloc _enc _last

  # Allow: export --yes  OR  export VOLSER --yes
  if [[ "$vol" == "--yes" && -z "$confirm" ]]; then
    confirm="--yes"
    vol=""
  fi
  [[ "$confirm" == "--yes" ]] || fail "$RC_USAGE" \
    "export changes cartridge ownership/location; use: $SCRIPT_NAME export [VOLSER] --yes"

  acquire_lock

  if [[ -z "$vol" ]]; then
    remembered=$(verify_remembered_for_export) || fail $? \
      "Cannot auto-export latest unloaded cartridge"
    IFS='|' read -r vol slot <<<"$remembered"
    auto=1
    info "Auto-detected latest unloaded volume=$vol remembered_location=$slot"
  else
    # Explicit VOLSER remains supported. If it is the remembered latest unload,
    # enforce the exact saved Slot; otherwise use normal eligibility validation.
    if remembered=$(verify_remembered_for_export "$vol" 2>/dev/null); then
      IFS='|' read -r _ slot <<<"$remembered"
      info "Explicit volume=$vol matches remembered latest unload at $slot"
    else
      verify_cartridge_eligible "$vol"
      row=$(get_cartridge "$vol") || fail "$RC_NOT_FOUND" "Cartridge not found: $vol"
      IFS='|' read -r curvol curlib _elem _media curloc _enc _last <<<"$row"
      slot=$curloc
    fi
  fi

  # Last-moment re-query before the robotic move. For auto mode this must still
  # be in the exact remembered slot; for explicit mode it must still be a Slot.
  row=$(get_cartridge "$vol") || fail "$RC_NOT_FOUND" "Cartridge not found immediately before export: $vol"
  IFS='|' read -r curvol curlib _elem _media curloc _enc _last <<<"$row"
  [[ "$curlib" == "$TS4500_LIBRARY" ]] || fail "$RC_VERIFY" \
    "Cannot export $vol: expected library='$TS4500_LIBRARY' current='$curlib'"
  [[ "$curloc" == Slot\(* ]] || fail "$RC_VERIFY" \
    "Cannot export $vol: cartridge is not in normal Slot: '$curloc'"
  if (( auto )); then
    [[ "$curloc" == "$slot" ]] || fail "$RC_VERIFY" \
      "Refusing auto-export: $vol moved since unload: remembered='$slot' current='$curloc'"
  fi

  info "Exporting volume=$vol from location=$curloc to I/O Slot"
  remove_data_cartridge "$vol" || exit $?
  if (( DRY_RUN )); then
    printf '%s\n' "$vol"
    return 0
  fi

  wait_cartridge_location "$vol" io || exit $?
  info "Verified exported: volume=$vol logical_library=Available location=I/O Slot(...)"
  clear_unloaded_state_if_volume "$vol"
  printf '%s\n' "$vol"
}

cmd_unload_export() {
  local vol=${1:-}
  local confirm=${2:-}
  local d state op contents lib _rest slot row curvol curlib _elem _media curloc _enc _last

  # Allow: unload-export --yes  OR  unload-export VOLSER --yes
  if [[ "$vol" == "--yes" && -z "$confirm" ]]; then
    confirm="--yes"
    vol=""
  fi
  [[ "$confirm" == "--yes" ]] || fail "$RC_USAGE" \
    "unload-export performs two robotic moves; use: $SCRIPT_NAME unload-export [VOLSER] --yes"

  acquire_lock

  if [[ -z "$vol" ]]; then
    d=$(get_target_drive) || fail "$RC_NOT_FOUND" \
      "Target drive F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW} not found"
    IFS='|' read -r state op contents lib _rest <<<"$d"
    [[ "$lib" == "$TS4500_LIBRARY" ]] || fail "$RC_VERIFY" \
      "Drive logical library mismatch: expected='$TS4500_LIBRARY' actual='$lib'"
    [[ "${state^^}" == "ONLINE" && "${op^^}" == "READY" ]] || fail "$RC_DRIVE_NOT_READY" \
      "Cannot unload-export: drive not ONLINE/READY: state='$state' operation='$op' contents='$contents'"
    is_failure_operation "$op" && fail "$RC_VERIFY" \
      "Cannot unload-export: drive operation indicates failure: '$op'"
    [[ -n "$contents" && "${contents^^}" != "EMPTY" ]] || fail "$RC_DRIVE_NOT_READY" \
      "Cannot unload-export: target drive is empty"
    vol=$contents
    info "Auto-detected mounted volume=$vol for unload-export"
  fi

  verify_loaded "$vol"
  move_from_drive || exit $?
  if (( DRY_RUN )); then
    info "DRY-RUN: would then remember returned Slot and export volume=$vol to I/O Slot"
    printf '%s\n' "$vol"
    return 0
  fi

  wait_drive_empty || exit $?
  wait_cartridge_location "$vol" slot || exit $?
  slot=$(get_cartridge_slot "$vol") || fail "$RC_VERIFY" \
    "Unload succeeded but returned Slot could not be determined for $vol"
  remember_unloaded "$vol" "$slot"

  # Strictly verify it is still in exactly the slot just remembered.
  row=$(get_cartridge "$vol") || fail "$RC_NOT_FOUND" "Cartridge disappeared before export: $vol"
  IFS='|' read -r curvol curlib _elem _media curloc _enc _last <<<"$row"
  [[ "$curlib" == "$TS4500_LIBRARY" && "$curloc" == "$slot" ]] || fail "$RC_VERIFY" \
    "Refusing export after unload: $vol changed: expected='$TS4500_LIBRARY/$slot' current='$curlib/$curloc'"

  info "Unload verified; exporting SAME volume=$vol from $slot to I/O Slot"
  remove_data_cartridge "$vol" || exit $?
  wait_cartridge_location "$vol" io || exit $?
  info "Verified unload-export complete: volume=$vol now logical_library=Available location=I/O Slot(...)"
  clear_unloaded_state_if_volume "$vol"
  printf '%s\n' "$vol"
}

# Auto-detect and validate the VOLSER currently loaded in the configured
# TS4500 target drive. Prints only the VOLSER on stdout.
get_loaded_volser() {
  local expected=${1:-}
  local d state op contents lib _rest

  d=$(get_target_drive) || return "$RC_NOT_FOUND"
  IFS='|' read -r state op contents lib _rest <<<"$d"

  [[ "$lib" == "$TS4500_LIBRARY" ]] || {
    err "Loaded-drive library mismatch: expected='$TS4500_LIBRARY' actual='$lib'"
    return "$RC_VERIFY"
  }
  [[ "${state^^}" == "ONLINE" ]] || {
    err "Tape drive is not ONLINE: state='$state'"
    return "$RC_DRIVE_NOT_READY"
  }
  is_failure_operation "$op" && {
    err "Tape drive operation indicates failure: '$op'"
    return "$RC_VERIFY"
  }
  [[ "${op^^}" == "READY" ]] || {
    err "Tape drive is not READY: operation='$op' contents='$contents'"
    return "$RC_DRIVE_NOT_READY"
  }
  [[ -n "$contents" && "${contents^^}" != "EMPTY" ]] || {
    err "Tape drive is READY but Contents is empty"
    return "$RC_DRIVE_NOT_READY"
  }
  if [[ -n "$expected" && "$contents" != "$expected" ]]; then
    err "Loaded VOLSER mismatch: expected='$expected' actual='$contents'"
    return "$RC_VERIFY"
  fi

  printf '%s\n' "$contents"
}

validate_os_tape_device() {
  command -v tar >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "tar not found in PATH"
  command -v mt >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "mt not found in PATH (install mt-st package)"

  [[ -e "$TAPE_DEVICE" ]] || fail "$RC_TAPE_DEVICE" "Tape device does not exist: $TAPE_DEVICE"
  [[ -c "$TAPE_DEVICE" ]] || fail "$RC_TAPE_DEVICE" "Tape device is not a character device: $TAPE_DEVICE"
  [[ -r "$TAPE_DEVICE" ]] || fail "$RC_TAPE_DEVICE" "Tape device is not readable: $TAPE_DEVICE"

  # Protect against another process actively using the drive. fuser is optional
  # because minimal systems may not have psmisc installed.
  if command -v fuser >/dev/null 2>&1; then
    local users
    users=$(fuser "$TAPE_DEVICE" 2>/dev/null || true)
    if [[ -n "${users//[[:space:]]/}" ]]; then
      fail "$RC_TAPE_DEVICE" "Tape device is already in use: $TAPE_DEVICE pids='${users}'"
    fi
  fi
}

# Strictly verify that NFS_MOUNT is itself the expected NFS mount, rather than
# merely a directory located on another filesystem. This prevents a failed NFS
# mount from silently sending a recovery to local root storage.
verify_nfs_target() {
  command -v findmnt >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "findmnt not found in PATH"
  command -v realpath >/dev/null 2>&1 || fail "$RC_DEPENDENCY" "realpath not found in PATH"

  [[ -d "$NFS_MOUNT" ]] || fail "$RC_NFS" "NFS mount directory does not exist: $NFS_MOUNT"

  local mi src fstype target expected_target
  mi=$(findmnt -n -T "$NFS_MOUNT" -o SOURCE,FSTYPE,TARGET 2>/dev/null || true)
  [[ -n "$mi" ]] || fail "$RC_NFS" "No filesystem found for NFS target: $NFS_MOUNT"
  IFS=$' \t' read -r src fstype target <<<"$mi"

  expected_target=$(realpath -e -- "$NFS_MOUNT" 2>/dev/null || true)
  [[ -n "$expected_target" ]] || fail "$RC_NFS" "Cannot resolve NFS mount point: $NFS_MOUNT"
  target=$(realpath -e -- "$target" 2>/dev/null || printf '%s' "$target")

  [[ "$target" == "$expected_target" ]] || fail "$RC_NFS" \
    "Expected '$NFS_MOUNT' to be a mount point, but its filesystem is mounted at '$target'"
  [[ "$fstype" == "nfs" || "$fstype" == "nfs4" ]] || fail "$RC_NFS" \
    "Expected NFS filesystem at $NFS_MOUNT, actual fstype='$fstype' source='$src'"
  [[ "$src" == "$NFS_SOURCE" ]] || fail "$RC_NFS" \
    "NFS source mismatch: expected='$NFS_SOURCE' actual='$src'"

  local probe="$NFS_MOUNT/.ts4500_write_test.$$"
  : > "$probe" 2>/dev/null || fail "$RC_NFS" "NFS mount is not writable: $NFS_MOUNT"
  rm -f -- "$probe" || warn "Could not remove NFS write-test file: $probe"

  info "NFS verified: source=$src fstype=$fstype target=$target"
}

ensure_destination_on_nfs() {
  local dest=$1
  local mount_abs dest_abs
  mount_abs=$(realpath -e -- "$NFS_MOUNT") || fail "$RC_NFS" "Cannot resolve NFS mount: $NFS_MOUNT"
  dest_abs=$(realpath -m -- "$dest") || fail "$RC_NFS" "Cannot resolve destination path: $dest"

  case "$dest_abs" in
    "$mount_abs"|"$mount_abs"/*) ;;
    *) fail "$RC_NFS" "Destination must be on/under NFS mount '$mount_abs': '$dest_abs'" ;;
  esac

  printf '%s\n' "$dest_abs"
}

show_os_tape_status() {
  local out rc
  set +e
  out=$(mt -f "$TAPE_DEVICE" status 2>&1)
  rc=$?
  set -e
  if (( rc != 0 )); then
    err "Unable to query tape device status: $TAPE_DEVICE"
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    return "$RC_TAPE_DEVICE"
  fi
  printf '%s\n' "$out"
}

rewind_os_tape() {
  info "Rewinding tape device: $TAPE_DEVICE"
  mt -f "$TAPE_DEVICE" rewind || fail "$RC_TAPE_DEVICE" "Failed to rewind tape device: $TAPE_DEVICE"
}

cmd_tape_status() {
  local expected=${1:-} vol
  acquire_lock

  vol=$(get_loaded_volser "$expected") || fail $? "No usable cartridge is loaded in the configured TS4500 drive"
  verify_loaded "$vol"
  validate_os_tape_device

  printf 'VOLSER       : %s\n' "$vol"
  printf 'Library      : %s\n' "$TS4500_LIBRARY"
  printf 'TS4500 Drive : F%s C%s R%s\n' "$TS4500_FRAME" "$TS4500_COLUMN" "$TS4500_ROW"
  printf 'Tape Device  : %s\n' "$TAPE_DEVICE"
  printf 'OS Status    :\n'
  show_os_tape_status || exit $?
}

verify_os_tape_flags() {
  local require_bot=${1:-0}
  local status
  status=$(show_os_tape_status) || return $?

  if ! grep -Eq '(^|[[:space:]])ONLINE([[:space:]]|$)' <<<"$status"; then
    err "OS tape device is not ONLINE: $TAPE_DEVICE"
    printf '%s\n' "$status" >&2
    return "$RC_TAPE_DEVICE"
  fi

  if (( require_bot )); then
    if ! grep -Eq '(^|[[:space:]])BOT([[:space:]]|$)' <<<"$status"; then
      err "OS tape device is ONLINE but not at BOT after rewind: $TAPE_DEVICE"
      printf '%s\n' "$status" >&2
      return "$RC_TAPE_DEVICE"
    fi
  fi

  return 0
}

cmd_tape_probe() {
  local expected="" entries="$TAPE_PROBE_ENTRIES" probe_timeout="$TAPE_PROBE_TIMEOUT"
  local vol status_before status_after probe_log tmp_out tmp_err
  local -a pipe_rc
  local tar_rc head_rc lines probe_failed=0 probe_reason=""

  while (( $# )); do
    case "$1" in
      --entries)
        [[ $# -ge 2 ]] || fail "$RC_USAGE" "tape-probe --entries requires a value"
        entries=$2
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || fail "$RC_USAGE" "tape-probe --timeout requires seconds"
        probe_timeout=$2
        shift 2
        ;;
      --)
        shift
        ;;
      -*)
        fail "$RC_USAGE" "Unknown tape-probe option: $1"
        ;;
      *)
        [[ -z "$expected" ]] || fail "$RC_USAGE" "tape-probe accepts at most one VOLSER"
        expected=$1
        shift
        ;;
    esac
  done

  require_uint probe-entries "$entries"
  require_uint probe-timeout "$probe_timeout"
  (( entries >= 1 )) || fail "$RC_USAGE" "tape-probe --entries must be >= 1"
  (( probe_timeout >= 1 )) || fail "$RC_USAGE" "tape-probe --timeout must be >= 1"

  acquire_lock

  vol=$(get_loaded_volser "$expected") || fail $? "No usable cartridge is loaded in the configured TS4500 drive"
  verify_loaded "$vol"
  validate_os_tape_device

  status_before=$(show_os_tape_status) || fail "$RC_TAPE_DEVICE" \
    "OS tape device is not ready/accessible: $TAPE_DEVICE"
  if ! grep -Eq '(^|[[:space:]])ONLINE([[:space:]]|$)' <<<"$status_before"; then
    printf '%s\n' "$status_before" >&2
    fail "$RC_TAPE_DEVICE" "OS tape device is not ONLINE: $TAPE_DEVICE"
  fi

  mkdir -p -- "$TAPE_READ_LOG_DIR" || fail "$RC_PROBE" "Cannot create probe log directory: $TAPE_READ_LOG_DIR"
  chmod 700 -- "$TAPE_READ_LOG_DIR" 2>/dev/null || true
  probe_log="${TAPE_READ_LOG_DIR%/}/tape_probe_${vol}_$(date '+%Y%m%d_%H%M%S').log"
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/ts4500_probe_out.XXXXXX") || fail "$RC_PROBE" "mktemp failed"
  tmp_err=$(mktemp "${TMPDIR:-/tmp}/ts4500_probe_err.XXXXXX") || {
    rm -f -- "$tmp_out"
    fail "$RC_PROBE" "mktemp failed"
  }

  if (( DRY_RUN )); then
    rm -f -- "$tmp_out" "$tmp_err"
    info "DRY-RUN: would rewind '$TAPE_DEVICE', list up to $entries tar entries with timeout=${probe_timeout}s, then rewind to BOT again"
    printf '%s\n' "$vol"
    return 0
  fi

  rewind_os_tape
  verify_os_tape_flags 1 || {
    rm -f -- "$tmp_out" "$tmp_err"
    fail "$RC_TAPE_DEVICE" "Tape did not reach BOT/ONLINE before probe"
  }

  info "Probing tar archive: volume=$vol device=$TAPE_DEVICE entries=$entries timeout=${probe_timeout}s"

  set +e
  timeout --signal=TERM --kill-after=5 "${probe_timeout}s" \
    tar -tvf "$TAPE_DEVICE" 2>"$tmp_err" | head -n "$entries" >"$tmp_out"
  pipe_rc=("${PIPESTATUS[@]}")
  set -e

  tar_rc=${pipe_rc[0]:-1}
  head_rc=${pipe_rc[1]:-1}
  lines=$(wc -l < "$tmp_out" | awk '{print $1}')

  # head intentionally closes stdout after N entries. GNU tar/timeout may then
  # return non-zero (for example EPIPE/SIGPIPE or timeout while skipping the
  # last sampled member). If N valid listing lines were already obtained, the
  # probe is considered successful unless stderr reports a real tape/archive
  # failure. If fewer than N lines were produced, tar itself must have exited 0.
  if (( lines == 0 )); then
    probe_failed=1
    probe_reason="tar produced no archive entries"
  elif grep -Eqi 'This does not look like a tar archive|Unexpected EOF|Error is not recoverable|Cannot open|Input/output error|I/O error|Read error' "$tmp_err"; then
    probe_failed=1
    probe_reason="tar reported an archive/tape read error"
  elif (( lines < entries && tar_rc != 0 )); then
    probe_failed=1
    probe_reason="probe ended early: entries=${lines}/${entries} tar_rc=$tar_rc head_rc=$head_rc"
  fi

  {
    printf 'TS4500 tape probe\n'
    printf 'timestamp=%s\n' "$(ts)"
    printf 'volume=%s\n' "$vol"
    printf 'device=%s\n' "$TAPE_DEVICE"
    printf 'requested_entries=%s\n' "$entries"
    printf 'listed_entries=%s\n' "$lines"
    printf 'tar_rc=%s\n' "$tar_rc"
    printf 'head_rc=%s\n' "$head_rc"
    printf '%s\n' '--- sample ---'
    cat "$tmp_out"
    if [[ -s "$tmp_err" ]]; then
      printf '%s\n' '--- tar stderr ---'
      cat "$tmp_err"
    fi
  } > "$probe_log"

  printf '%s\n' '--- TAR PROBE SAMPLE ---'
  cat "$tmp_out"
  printf '%s\n' '--- END PROBE SAMPLE ---'

  # Always restore BOT after probe, even when the listing itself failed.
  set +e
  mt -f "$TAPE_DEVICE" rewind
  local rewind_rc=$?
  set -e
  if (( rewind_rc != 0 )); then
    probe_failed=1
    probe_reason="${probe_reason:+$probe_reason; }final rewind failed rc=$rewind_rc"
  else
    status_after=$(show_os_tape_status 2>&1 || true)
    if ! grep -Eq '(^|[[:space:]])ONLINE([[:space:]]|$)' <<<"$status_after" || \
       ! grep -Eq '(^|[[:space:]])BOT([[:space:]]|$)' <<<"$status_after"; then
      probe_failed=1
      probe_reason="${probe_reason:+$probe_reason; }final status is not BOT ONLINE"
    fi
  fi

  rm -f -- "$tmp_out" "$tmp_err"

  if (( probe_failed )); then
    err "Tape probe FAILED: volume=$vol reason=$probe_reason log=$probe_log"
    [[ -n "${status_after:-}" ]] && printf '%s\n' "$status_after" >&2
    exit "$RC_PROBE"
  fi

  # Reconfirm robotics state after tape movement/rewind.
  verify_loaded "$vol"
  info "Tape probe PASSED: volume=$vol entries=$lines device=$TAPE_DEVICE final_state=BOT/ONLINE log=$probe_log"
  printf '%s\n' "$vol"
}

cmd_tape_read() {
  local expected="" dest="" allow_existing=0 no_rewind=0 preserve_owner=0
  local vol log_file tar_rc file_count bytes

  # Command-specific arguments may appear in any order.
  while (( $# )); do
    case "$1" in
      --to)
        [[ $# -ge 2 ]] || fail "$RC_USAGE" "tape-read --to requires a directory"
        dest=$2
        shift 2
        ;;
      --allow-existing)
        allow_existing=1
        shift
        ;;
      --no-rewind)
        no_rewind=1
        shift
        ;;
      --preserve-owner)
        preserve_owner=1
        shift
        ;;
      --)
        shift
        ;;
      -*)
        fail "$RC_USAGE" "Unknown tape-read option: $1"
        ;;
      *)
        [[ -z "$expected" ]] || fail "$RC_USAGE" "tape-read accepts at most one VOLSER"
        expected=$1
        shift
        ;;
    esac
  done

  acquire_lock

  vol=$(get_loaded_volser "$expected") || fail $? "No usable cartridge is loaded in the configured TS4500 drive"
  info "Tape-read VOLSER=$vol detected from TS4500 drive F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW}"

  # Cross-check robotics inventory before touching the OS tape device.
  verify_loaded "$vol"
  validate_os_tape_device
  # Confirm the kernel/IBM tape driver can actually communicate with this OS
  # device before touching the recovery destination or attempting a rewind.
  show_os_tape_status >/dev/null || fail "$RC_TAPE_DEVICE" \
    "OS tape device is not ready/accessible: $TAPE_DEVICE"
  info "OS tape status verified: $TAPE_DEVICE"
  verify_nfs_target

  [[ -n "$dest" ]] || dest="${NFS_MOUNT%/}/$vol"
  dest=$(ensure_destination_on_nfs "$dest")

  mkdir -p -- "$dest" || fail "$RC_NFS" "Cannot create extraction destination: $dest"
  [[ -w "$dest" ]] || fail "$RC_NFS" "Extraction destination is not writable: $dest"

  if (( ! allow_existing )); then
    if find "$dest" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      fail "$RC_NFS" "Destination is not empty: $dest (use --allow-existing to permit overwrite/merge)"
    fi
  fi

  mkdir -p -- "$TAPE_READ_LOG_DIR" || fail "$RC_TAR" "Cannot create read log directory: $TAPE_READ_LOG_DIR"
  chmod 700 -- "$TAPE_READ_LOG_DIR" 2>/dev/null || true
  log_file="${TAPE_READ_LOG_DIR%/}/tape_read_${vol}_$(date '+%Y%m%d_%H%M%S').log"

  info "Tape device verified: $TAPE_DEVICE"
  info "Recovery destination: $dest"
  if command -v df >/dev/null 2>&1; then
    df -hP "$NFS_MOUNT" >&2 || true
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: would $([[ $no_rewind -eq 1 ]] && printf 'not rewind; ' || printf 'rewind; ')extract tar archive from '$TAPE_DEVICE' to '$dest' owner_policy=$([[ $preserve_owner -eq 1 ]] && printf 'preserve' || printf 'nfs-safe-no-same-owner')"
    printf '%s\n' "$dest"
    return 0
  fi

  (( no_rewind )) || rewind_os_tape

  # Re-check that the same cartridge is still READY immediately before opening
  # the tape device. This closes the window between inventory validation and I/O.
  verify_loaded "$vol"

  info "Starting tar extraction: device=$TAPE_DEVICE volume=$vol destination=$dest"
  info "Tar verbose log: $log_file"

  local -a tar_extract_args
  if (( preserve_owner )); then
    # This requires the destination filesystem/NFS export to permit chown to the
    # archived UID/GID. root_squash commonly makes that impossible.
    tar_extract_args=(-xvf "$TAPE_DEVICE" -C "$dest")
    info "Tar owner policy: preserve archived UID/GID (--preserve-owner requested)"
  else
    # GNU tar run as root otherwise attempts to restore archived UID/GID and can
    # finish with rc=2 on root_squash NFS even when file data was read correctly.
    # Do not hide rc=2: prevent the ownership error instead, so genuine archive
    # and tape I/O failures remain fatal.
    tar_extract_args=(--no-same-owner -xvf "$TAPE_DEVICE" -C "$dest")
    info "Tar owner policy: NFS-safe --no-same-owner (ownership determined by NFS/server)"
  fi

  set +e
  tar "${tar_extract_args[@]}" 2>&1 | tee -a "$log_file"
  tar_rc=${PIPESTATUS[0]}
  set -e

  if (( tar_rc != 0 )); then
    err "tar extraction failed: rc=$tar_rc volume=$vol device=$TAPE_DEVICE destination=$dest log=$log_file"
    exit "$RC_TAR"
  fi

  # Confirm the library still sees the expected cartridge loaded after data I/O.
  verify_loaded "$vol"

  file_count=$(find "$dest" -type f 2>/dev/null | wc -l | awk '{print $1}')
  bytes=$(du -sb -- "$dest" 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$bytes" ]] || bytes="unknown"

  info "Tape read completed successfully: volume=$vol files=$file_count bytes=$bytes destination=$dest"
  info "Tape remains mounted; run '$SCRIPT_NAME unload' or '$SCRIPT_NAME unload-export --yes' when finished"
  printf '%s\n' "$dest"
}

verify_recovery_output() {
  local dest=$1
  [[ -d "$dest" ]] || {
    err "Recovery destination does not exist after tar extraction: $dest"
    return "$RC_RECOVERY"
  }

  # Production recovery expects actual files, not only an empty directory tree.
  if ! find "$dest" -type f -print -quit 2>/dev/null | grep -q .; then
    err "Recovery completed but no regular files were found under: $dest"
    return "$RC_RECOVERY"
  fi

  local files bytes
  files=$(find "$dest" -type f 2>/dev/null | wc -l | awk '{print $1}')
  bytes=$(du -sb -- "$dest" 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$bytes" ]] || bytes="unknown"
  info "Recovered-output verification PASSED: destination=$dest files=$files bytes=$bytes"
}

cmd_recover() {
  local expected="" dest="" allow_existing=0 preserve_owner=0
  local probe_entries="$TAPE_PROBE_ENTRIES" probe_timeout="$TAPE_PROBE_TIMEOUT"
  local after="unload" confirm=0
  local d state op contents lib _rest vol dest_abs

  while (( $# )); do
    case "$1" in
      --to)
        [[ $# -ge 2 ]] || fail "$RC_USAGE" "recover --to requires a directory"
        dest=$2
        shift 2
        ;;
      --allow-existing)
        allow_existing=1
        shift
        ;;
      --preserve-owner)
        preserve_owner=1
        shift
        ;;
      --probe-entries)
        [[ $# -ge 2 ]] || fail "$RC_USAGE" "recover --probe-entries requires a value"
        probe_entries=$2
        shift 2
        ;;
      --probe-timeout)
        [[ $# -ge 2 ]] || fail "$RC_USAGE" "recover --probe-timeout requires seconds"
        probe_timeout=$2
        shift 2
        ;;
      --after)
        [[ $# -ge 2 ]] || fail "$RC_USAGE" "recover --after requires keep, unload, or export"
        after=$2
        shift 2
        ;;
      --export)
        after="export"
        shift
        ;;
      --yes)
        confirm=1
        shift
        ;;
      --)
        shift
        ;;
      -*)
        fail "$RC_USAGE" "Unknown recover option: $1"
        ;;
      *)
        [[ -z "$expected" ]] || fail "$RC_USAGE" "recover accepts at most one VOLSER"
        expected=$1
        shift
        ;;
    esac
  done

  require_uint probe-entries "$probe_entries"
  require_uint probe-timeout "$probe_timeout"
  (( probe_entries >= 1 )) || fail "$RC_USAGE" "recover --probe-entries must be >= 1"
  (( probe_timeout >= 1 )) || fail "$RC_USAGE" "recover --probe-timeout must be >= 1"
  case "$after" in
    keep|unload|export) ;;
    *) fail "$RC_USAGE" "recover --after must be keep, unload, or export" ;;
  esac
  if [[ "$after" == "export" && "$confirm" -ne 1 ]]; then
    fail "$RC_USAGE" "recover --after export moves media to I/O Slot; add --yes"
  fi

  acquire_lock

  # Reuse an already READY cartridge, otherwise load the requested/selected one.
  d=$(get_target_drive) || fail "$RC_NOT_FOUND" \
    "Target drive F${TS4500_FRAME},C${TS4500_COLUMN},R${TS4500_ROW} not found"
  IFS='|' read -r state op contents lib _rest <<<"$d"

  [[ "$lib" == "$TS4500_LIBRARY" ]] || fail "$RC_VERIFY" \
    "Drive logical library mismatch: expected='$TS4500_LIBRARY' actual='$lib'"
  [[ "${state^^}" == "ONLINE" ]] || fail "$RC_DRIVE_NOT_READY" \
    "Recovery cannot start: drive is not ONLINE: state='$state'"
  is_failure_operation "$op" && fail "$RC_VERIFY" \
    "Recovery cannot start: drive operation indicates failure: '$op'"

  if [[ "${op^^}" == "EMPTY" && "${contents^^}" == "EMPTY" ]]; then
    if [[ -n "$expected" ]]; then
      vol=$expected
    else
      vol=$(select_volume) || fail "$RC_NO_CANDIDATE" \
        "No eligible cartridges in library '$TS4500_LIBRARY'"
      info "Recovery auto-selected volume=$vol policy=$SELECTION_POLICY"
    fi
    info "Recovery drive is EMPTY; loading volume=$vol"
    cmd_load "$vol"
  elif [[ "${op^^}" == "READY" && -n "$contents" && "${contents^^}" != "EMPTY" ]]; then
    vol=$contents
    if [[ -n "$expected" && "$expected" != "$vol" ]]; then
      fail "$RC_VERIFY" "Recovery requested VOLSER='$expected' but drive currently contains '$vol'"
    fi
    info "Recovery reusing already loaded volume=$vol"
    verify_loaded "$vol"
  else
    fail "$RC_DRIVE_NOT_READY" \
      "Recovery cannot start from current drive state: state='$state' operation='$op' contents='$contents'"
  fi

  [[ -n "$dest" ]] || dest="${NFS_MOUNT%/}/$vol"

  printf '%s\n' '============================================================' >&2
  printf '%s\n' 'TS4500 PRODUCTION RECOVERY' >&2
  printf '%s\n' '============================================================' >&2
  printf 'VOLSER       : %s\n' "$vol" >&2
  printf 'Library      : %s\n' "$TS4500_LIBRARY" >&2
  printf 'TS4500 Drive : F%s C%s R%s\n' "$TS4500_FRAME" "$TS4500_COLUMN" "$TS4500_ROW" >&2
  printf 'Tape Device  : %s\n' "$TAPE_DEVICE" >&2
  printf 'NFS Source   : %s\n' "$NFS_SOURCE" >&2
  printf 'Destination  : %s\n' "$dest" >&2
  printf 'Probe        : %s entries / %ss timeout\n' "$probe_entries" "$probe_timeout" >&2
  printf 'Owner Policy : %s\n' "$([[ $preserve_owner -eq 1 ]] && printf 'preserve archived UID/GID' || printf 'NFS-safe --no-same-owner')" >&2
  printf 'After        : %s\n' "$after" >&2
  printf '%s\n' '============================================================' >&2

  # Phase 1: probe. cmd_tape_probe always attempts to return the tape to BOT.
  cmd_tape_probe "$vol" --entries "$probe_entries" --timeout "$probe_timeout"

  # Phase 2: full extraction. Do not use --no-rewind in the production flow;
  # the read starts from BOT even if probe implementation changes later.
  local -a tape_read_opts
  tape_read_opts=("$vol" --to "$dest")
  (( allow_existing )) && tape_read_opts+=(--allow-existing)
  (( preserve_owner )) && tape_read_opts+=(--preserve-owner)
  cmd_tape_read "${tape_read_opts[@]}"

  dest_abs=$(realpath -m -- "$dest") || fail "$RC_RECOVERY" "Cannot resolve recovery destination: $dest"
  verify_recovery_output "$dest_abs" || fail $? "Recovered-output verification failed"
  verify_loaded "$vol"

  # Only after probe + full tar restore + output verification succeeded may the
  # production flow move media. Failure anywhere above leaves the tape mounted.
  case "$after" in
    keep)
      info "Recovery SUCCESS: volume=$vol remains mounted by request"
      ;;
    unload)
      info "Recovery SUCCESS: unloading volume=$vol to normal Slot"
      cmd_unload "$vol"
      ;;
    export)
      info "Recovery SUCCESS: unloading and exporting SAME volume=$vol to I/O Slot"
      cmd_unload_export "$vol" --yes
      ;;
  esac

  info "Production recovery COMPLETED: volume=$vol destination=$dest_abs after=$after"
  printf '%s\n' "$dest_abs"
}

cmd_test_cycle() {
  local vol=${1:-}
  acquire_lock

  drive_check_available
  if [[ -z "$vol" ]]; then
    vol=$(select_volume) || fail "$RC_NO_CANDIDATE" \
      "No eligible cartridges in library '$TS4500_LIBRARY'"
    info "Auto-selected volume=$vol policy=$SELECTION_POLICY"
  fi
  verify_cartridge_eligible "$vol"
  drive_check_available

  move_to_drive "$vol" || exit $?
  if (( DRY_RUN )); then
    return 0
  fi
  wait_drive_loaded "$vol" || exit $?
  verify_loaded "$vol"

  info "Load phase passed; starting unload phase for test-cycle"
  move_from_drive || exit $?
  wait_drive_empty || exit $?
  wait_cartridge_location "$vol" slot || exit $?
  local returned_slot
  returned_slot=$(get_cartridge_slot "$vol") || fail "$RC_VERIFY" \
    "Test-cycle unload completed but returned Slot could not be determined for $vol"
  remember_unloaded "$vol" "$returned_slot"

  info "Test-cycle PASSED: volume=$vol load/READY/unload/EMPTY/return-to-slot verified at $returned_slot"
  printf '%s\n' "$vol"
}

# ----------------------------- Argument parsing -----------------------------
while (( $# )); do
  case "$1" in
    --ip)              [[ $# -ge 2 ]] || fail "$RC_USAGE" "--ip requires a value"; TS4500_IP=$2; shift 2 ;;
    --user)            [[ $# -ge 2 ]] || fail "$RC_USAGE" "--user requires a value"; TS4500_USER=$2; shift 2 ;;
    --password-file)   [[ $# -ge 2 ]] || fail "$RC_USAGE" "--password-file requires a value"; TS4500_PASSWORD_FILE=$2; shift 2 ;;
    --jar)             [[ $# -ge 2 ]] || fail "$RC_USAGE" "--jar requires a value"; TS4500_JAR=$2; shift 2 ;;
    --library)         [[ $# -ge 2 ]] || fail "$RC_USAGE" "--library requires a value"; TS4500_LIBRARY=$2; shift 2 ;;
    --frame)           [[ $# -ge 2 ]] || fail "$RC_USAGE" "--frame requires a value"; TS4500_FRAME=$2; shift 2 ;;
    --column)          [[ $# -ge 2 ]] || fail "$RC_USAGE" "--column requires a value"; TS4500_COLUMN=$2; shift 2 ;;
    --row)             [[ $# -ge 2 ]] || fail "$RC_USAGE" "--row requires a value"; TS4500_ROW=$2; shift 2 ;;
    --policy)          [[ $# -ge 2 ]] || fail "$RC_USAGE" "--policy requires a value"; SELECTION_POLICY=$2; shift 2 ;;
    --query-timeout)   [[ $# -ge 2 ]] || fail "$RC_USAGE" "--query-timeout requires a value"; QUERY_TIMEOUT=$2; shift 2 ;;
    --move-timeout)    [[ $# -ge 2 ]] || fail "$RC_USAGE" "--move-timeout requires a value"; MOVE_TIMEOUT=$2; shift 2 ;;
    --verify-timeout)  [[ $# -ge 2 ]] || fail "$RC_USAGE" "--verify-timeout requires a value"; VERIFY_TIMEOUT=$2; shift 2 ;;
    --poll)            [[ $# -ge 2 ]] || fail "$RC_USAGE" "--poll requires a value"; POLL_INTERVAL=$2; shift 2 ;;
    --lock-file)       [[ $# -ge 2 ]] || fail "$RC_USAGE" "--lock-file requires a value"; LOCK_FILE=$2; shift 2 ;;
    --state-file)      [[ $# -ge 2 ]] || fail "$RC_USAGE" "--state-file requires a value"; STATE_FILE=$2; shift 2 ;;
    --tape-device)     [[ $# -ge 2 ]] || fail "$RC_USAGE" "--tape-device requires a value"; TAPE_DEVICE=$2; shift 2 ;;
    --nfs-source)      [[ $# -ge 2 ]] || fail "$RC_USAGE" "--nfs-source requires a value"; NFS_SOURCE=$2; shift 2 ;;
    --nfs-mount)       [[ $# -ge 2 ]] || fail "$RC_USAGE" "--nfs-mount requires a value"; NFS_MOUNT=$2; shift 2 ;;
    --read-log-dir)    [[ $# -ge 2 ]] || fail "$RC_USAGE" "--read-log-dir requires a value"; TAPE_READ_LOG_DIR=$2; shift 2 ;;
    --probe-entries)   [[ $# -ge 2 ]] || fail "$RC_USAGE" "--probe-entries requires a value"; TAPE_PROBE_ENTRIES=$2; shift 2 ;;
    --probe-timeout)   [[ $# -ge 2 ]] || fail "$RC_USAGE" "--probe-timeout requires a value"; TAPE_PROBE_TIMEOUT=$2; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --quiet)           QUIET=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -V|--version)      printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
    --)                shift; break ;;
    -*)                 fail "$RC_USAGE" "Unknown global option: $1" ;;
    *)                  break ;;
  esac
done

(( $# >= 1 )) || { usage >&2; exit "$RC_USAGE"; }
COMMAND=$1
shift

validate_settings

case "$COMMAND" in
  status)
    (( $# == 0 )) || fail "$RC_USAGE" "status takes no arguments"
    cmd_status
    ;;
  drive-check)
    (( $# == 0 )) || fail "$RC_USAGE" "drive-check takes no arguments"
    drive_check_available
    ;;
  candidates)
    (( $# == 0 )) || fail "$RC_USAGE" "candidates takes no arguments"
    cmd_candidates
    ;;
  select)
    (( $# == 0 )) || fail "$RC_USAGE" "select takes no arguments"
    cmd_select
    ;;
  load)
    (( $# <= 1 )) || fail "$RC_USAGE" "load accepts zero or one VOLSER"
    cmd_load "${1:-}"
    ;;
  verify-loaded)
    (( $# == 1 )) || fail "$RC_USAGE" "verify-loaded requires VOLSER"
    verify_loaded "$1"
    ;;
  unload)
    (( $# <= 1 )) || fail "$RC_USAGE" "unload accepts zero or one VOLSER"
    cmd_unload "${1:-}"
    ;;
  last-unloaded)
    (( $# == 0 )) || fail "$RC_USAGE" "last-unloaded takes no arguments"
    cmd_last_unloaded
    ;;
  export)
    (( $# >= 1 && $# <= 2 )) || fail "$RC_USAGE" "export requires [VOLSER] --yes"
    cmd_export "${1:-}" "${2:-}"
    ;;
  unload-export)
    (( $# >= 1 && $# <= 2 )) || fail "$RC_USAGE" "unload-export requires [VOLSER] --yes"
    cmd_unload_export "${1:-}" "${2:-}"
    ;;
  tape-status)
    (( $# <= 1 )) || fail "$RC_USAGE" "tape-status accepts zero or one VOLSER"
    cmd_tape_status "${1:-}"
    ;;
  tape-probe)
    cmd_tape_probe "$@"
    ;;
  tape-read)
    cmd_tape_read "$@"
    ;;
  recover)
    cmd_recover "$@"
    ;;
  test-cycle)
    (( $# <= 1 )) || fail "$RC_USAGE" "test-cycle accepts zero or one VOLSER"
    cmd_test_cycle "${1:-}"
    ;;
  drive-summary)
    (( $# == 0 )) || fail "$RC_USAGE" "drive-summary takes no arguments"
    view_drive_summary
    ;;
  cartridges)
    (( $# == 0 )) || fail "$RC_USAGE" "cartridges takes no arguments"
    view_cartridges
    ;;
  *)
    fail "$RC_USAGE" "Unknown command: $COMMAND"
    ;;
esac
