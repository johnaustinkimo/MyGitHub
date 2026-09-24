#!/usr/bin/env bash
# tape_to_tape_migrate_v1.0.sh
# TS4500 -> Scalar i3 raw tar tape-file migration wrapper.
#
# Design:
#   * One TS4500 cartridge/tar archive -> one Scalar i3 tape file.
#   * Scalar destination uses IBM non-rewinding tape device so multiple source
#     archives can coexist on one higher-capacity destination cartridge.
#   * Original tar byte stream is copied without extract/re-tar, preserving tar
#     header metadata (uid/gid/mode/mtime/path) as stored on the source tape.
#   * Existing destination data is never overwritten unless explicitly allowed.
#   * Manifest records destination tape-file index -> source VOLSER mapping.
#
# Production baseline: v1.0
set -Eeuo pipefail
umask 077

VERSION="1.0"
SCRIPT_NAME="$(basename -- "$0")"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

TS4500_OPS="${TS4500_OPS:-/ws/ts4500Toscalari3/ts4500_ops_v1.5.sh}"
SCALAR_OPS="${SCALAR_OPS:-/ws/ts4500Toscalari3/scalari3_tape_write_v1.3.sh}"

SRC_TAPE_LINK="${T2T_SRC_TAPE_DEVICE:-/dev/IBMtape0}"
DST_TAPE_LINK="${T2T_DST_TAPE_DEVICE:-/dev/tapedrv_test}"
SRC_NOREWIND="${T2T_SRC_NOREWIND:-}"
DST_NOREWIND="${T2T_DST_NOREWIND:-}"

LOG_DIR="${T2T_LOG_DIR:-/var/log/tape_to_tape_migrate}"
STATE_DIR="${T2T_STATE_DIR:-/var/lib/tape_to_tape_migrate}"
MANIFEST_FILE="${T2T_MANIFEST_FILE:-${STATE_DIR}/manifest.tsv}"
LOCK_FILE="${T2T_LOCK_FILE:-/run/lock/tape_to_tape_migrate.lock}"

DD_BS="${T2T_DD_BS:-1M}"
HEARTBEAT_SEC="${T2T_HEARTBEAT_SEC:-60}"
PROBE_ENTRIES="${T2T_PROBE_ENTRIES:-20}"
PROBE_TIMEOUT="${T2T_PROBE_TIMEOUT:-120}"
VERIFY_MODE="${T2T_VERIFY_MODE:-probe}" # none|probe|full
SOURCE_AFTER="${T2T_SOURCE_AFTER:-unload}" # unload|export
DEST_AFTER="${T2T_DEST_AFTER:-keep}" # keep|unload

DRY_RUN=0
YES=0
OVERWRITE_DEST=0
SKIP_SINGLE_FILE_CHECK=0
DEST_LOADED_VOLSER=""
COMMAND=""

SRC_RESOLVED=""
DST_RESOLVED=""
DEST_VOLSER=""
LOADED_SOURCE_VOLSER=""
RUN_LOG=""

# Source VOLSERs supplied to migrate. Empty means auto-select one via ts4500_ops.
declare -a SOURCE_VOLS=()

# Manifest schema (tab separated):
# destination_volser  tape_file_index  source_volser  bytes  copied_at  verify  source_device  destination_device

# ----------------------------- Logging ---------------------------------
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ printf '%s [INFO] %s\n' "$(ts)" "$*"; }
ok(){ printf '%s [OK] %s\n' "$(ts)" "$*"; }
warn(){ printf '%s [WARN] %s\n' "$(ts)" "$*" >&2; }
err(){ printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die(){ local rc="$1"; shift; err "$*"; exit "$rc"; }

fmt_bytes(){
  local n="${1:-0}"
  awk -v n="$n" 'BEGIN {
    split("B KiB MiB GiB TiB PiB",u," "); i=1; v=n+0;
    while (v>=1024 && i<6) {v/=1024; i++}
    if (i==1) printf "%.0f %s",v,u[i]; else if (v>=100) printf "%.0f %s",v,u[i]; else if (v>=10) printf "%.1f %s",v,u[i]; else printf "%.2f %s",v,u[i]
  }'
}

fmt_elapsed(){
  local sec="${1:-0}" h m s
  (( sec < 0 )) && sec=0
  h=$((sec/3600)); m=$(((sec%3600)/60)); s=$((sec%60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

usage(){
cat <<USAGE
${SCRIPT_NAME} v${VERSION} - TS4500 -> Scalar i3 raw tape-file migration

Usage:
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} manifest [DEST_VOLSER]
  ${SCRIPT_NAME} migrate [SOURCE_VOLSER ...] --yes [options]
  ${SCRIPT_NAME} verify DEST_VOLSER [--verify probe|full]

Core model:
  TS4500 OAT016L7 tar stream -> Scalar tape file #0
  TS4500 OAT017L7 tar stream -> Scalar tape file #1
  TS4500 OAT022L7 tar stream -> Scalar tape file #2

Commands:
  status
      Show configured wrappers, rewinding/non-rewinding devices and OS status.

  manifest [DEST_VOLSER]
      Show all migration mappings, or mappings for one Scalar destination VOLSER.

  migrate [SOURCE_VOLSER ...] --yes
      Load/verify source TS4500 tape(s), load one Scalar destination cartridge,
      append each source tar byte stream as a separate Scalar tape file, verify,
      record manifest, then unload/export source cartridges as configured.
      If no SOURCE_VOLSER is supplied, TS4500 auto-selects one source cartridge.

  verify DEST_VOLSER
      Verify manifest-managed tape files on an ALREADY LOADED Scalar cartridge.
      The command does not call Scalar robotics load because the existing backend
      does not provide a load-by-specific-VOLSER interface.

Options:
  --ts-ops PATH            TS4500 wrapper (default: ${TS4500_OPS})
  --scalar-ops PATH        Scalar wrapper (default: ${SCALAR_OPS})
  --src-device DEV         TS4500 rewinding device (default: ${SRC_TAPE_LINK})
  --src-norewind DEV       TS4500 non-rewind device; auto-derived as IBMtapeXn
  --dst-device DEV         Scalar rewinding/persistent link (default: ${DST_TAPE_LINK})
  --dst-norewind DEV       Scalar non-rewind device; auto-derived as IBMtapeXn
  --dest-loaded VOLSER     Do not call Scalar load; use already loaded VOLSER
  --source-after MODE      unload|export (default: ${SOURCE_AFTER})
  --dest-after MODE        keep|unload (default: ${DEST_AFTER})
  --verify MODE            none|probe|full (default: ${VERIFY_MODE})
  --probe-entries N        tar entries shown per destination tape file (default: ${PROBE_ENTRIES})
  --probe-timeout SEC      probe timeout per tape file (default: ${PROBE_TIMEOUT})
  --heartbeat-sec SEC      raw copy heartbeat interval (default: ${HEARTBEAT_SEC})
  --dd-bs SIZE             dd read/write request size (default: ${DD_BS})
  --manifest FILE          manifest TSV path (default: ${MANIFEST_FILE})
  --overwrite-destination  Allow BOT overwrite when loaded destination has data.
                           Existing manifest rows for that destination are cleared.
  --skip-single-file-check Skip check that source cartridge has only one tape file.
                           NOT recommended.
  --dry-run                Print mutating commands; do not move/write media.
  --yes                    Required for migrate and destination overwrite.
  -h, --help               Show help.
  -V, --version            Show version.

Examples:
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} migrate OAT016L7 OAT017L7 OAT022L7 --yes --verify probe --dest-after keep
  ${SCRIPT_NAME} migrate OAT016L7 --yes --source-after export
  ${SCRIPT_NAME} migrate OAT022L7 --yes --dest-loaded CDT002L9
  ${SCRIPT_NAME} manifest CDT002L9
  ${SCRIPT_NAME} verify CDT002L9 --verify full --dest-loaded CDT002L9

Safety notes:
  * Destination writes use a non-rewinding IBM tape node.
  * A known destination resumes with: rewind + fsf <manifest-file-count>.
  * If data exists beyond the manifest count, append is refused.
  * Unknown non-blank destination data is never overwritten unless
    --overwrite-destination --yes is supplied.
  * Copy/verify failure leaves destination loaded for investigation.
USAGE
}

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die 10 "Required command not found: $1"; }
need_exec(){ [[ -x "$1" ]] || die 11 "Required executable not found or not executable: $1"; }
require_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die 12 "Must run as root"; }
valid_volser(){ [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$ ]]; }

run_cmd(){
  if (( DRY_RUN )); then
    printf '%s [DRYRUN] ' "$(ts)"
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

acquire_lock(){
  need_cmd flock
  mkdir -p -- "$(dirname -- "$LOCK_FILE")"
  exec 9>"$LOCK_FILE" || die 13 "Cannot open lock: $LOCK_FILE"
  flock -n 9 || die 14 "Another tape-to-tape migration is already running: $LOCK_FILE"
}

init_dirs(){
  mkdir -p -- "$LOG_DIR" "$STATE_DIR" "$(dirname -- "$MANIFEST_FILE")"
  chmod 700 -- "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
  if [[ ! -e "$MANIFEST_FILE" ]]; then
    printf '#destination_volser\ttape_file_index\tsource_volser\tbytes\tcopied_at\tverify\tsource_device\tdestination_device\n' > "$MANIFEST_FILE"
    chmod 600 "$MANIFEST_FILE" 2>/dev/null || true
  fi
}

# ------------------------- Device resolution -----------------------------
resolve_char_device(){
  local link="$1" outvar="$2" resolved_path
  [[ -e "$link" || -L "$link" ]] || die 20 "Tape device not found: $link"
  resolved_path="$(readlink -f -- "$link" 2>/dev/null || true)"
  [[ -n "$resolved_path" ]] || die 21 "Cannot resolve tape device: $link"
  [[ -c "$resolved_path" ]] || die 22 "Not a character tape device: $resolved_path"
  printf -v "$outvar" '%s' "$resolved_path"
}

derive_norewind(){
  local base="$1" explicit="$2" outvar="$3" resolved candidate
  if [[ -n "$explicit" ]]; then
    resolve_char_device "$explicit" resolved
    printf -v "$outvar" '%s' "$resolved"
    return 0
  fi

  resolve_char_device "$base" resolved
  case "$resolved" in
    /dev/IBMtape*n)
      candidate="$resolved"
      ;;
    /dev/IBMtape*)
      candidate="${resolved}n"
      ;;
    *)
      die 23 "Cannot auto-derive IBM non-rewind node from '$resolved'; use explicit --src-norewind/--dst-norewind"
      ;;
  esac
  [[ -c "$candidate" ]] || die 24 "Non-rewinding tape device not found: $candidate"
  printf -v "$outvar" '%s' "$candidate"
}

resolve_devices(){
  resolve_char_device "$SRC_TAPE_LINK" SRC_RESOLVED
  resolve_char_device "$DST_TAPE_LINK" DST_RESOLVED
  derive_norewind "$SRC_TAPE_LINK" "$SRC_NOREWIND" SRC_NOREWIND
  derive_norewind "$DST_TAPE_LINK" "$DST_NOREWIND" DST_NOREWIND
}

mt_status(){ local dev="$1"; mt -f "$dev" status 2>&1; }
require_online(){
  local dev="$1" status
  status="$(mt_status "$dev")" || die 25 "mt status failed for $dev: $status"
  grep -Eq '(^|[[:space:]])ONLINE([[:space:]]|$)' <<<"$status" || {
    printf '%s\n' "$status" >&2
    die 26 "Tape device is not ONLINE: $dev"
  }
}

rewind_tape(){
  local dev="$1"
  log "Rewinding tape: $dev"
  run_cmd mt -f "$dev" rewind
}

# Read one tape record from current position into a temporary file.
# Return codes:
#   0 -> data present
#   1 -> no data / filemark / logical EOD
#   2 -> unknown read error
peek_current_data(){
  local dev="$1" tmp errf rc size
  tmp="$(mktemp "${TMPDIR:-/tmp}/t2t_peek.XXXXXX")"
  errf="$(mktemp "${TMPDIR:-/tmp}/t2t_peek_err.XXXXXX")"
  if (( DRY_RUN )); then
    rm -f -- "$tmp" "$errf"
    return 1
  fi
  if LC_ALL=C dd if="$dev" of="$tmp" bs="$DD_BS" count=1 status=none 2>"$errf"; then
    rc=0
  else
    rc=$?
  fi
  size="$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)"
  if (( size > 0 )); then
    rm -f -- "$tmp" "$errf"
    return 0
  fi
  if (( rc == 0 )); then
    rm -f -- "$tmp" "$errf"
    return 1
  fi
  if grep -Eqi 'Input/output error|I/O error|Permission denied|No such device|Device or resource busy' "$errf"; then
    err "Tape peek failed on $dev: $(tr '\n' ' ' < "$errf")"
    rm -f -- "$tmp" "$errf"
    return 2
  fi
  rm -f -- "$tmp" "$errf"
  return 1
}

# ----------------------------- Manifest ---------------------------------
manifest_count(){
  local dest="$1"
  awk -F'\t' -v d="$dest" '$0 !~ /^#/ && $1==d {n++} END{print n+0}' "$MANIFEST_FILE"
}

manifest_bytes(){
  local dest="$1"
  awk -F'\t' -v d="$dest" '$0 !~ /^#/ && $1==d {s+=$4} END{printf "%.0f\n",s+0}' "$MANIFEST_FILE"
}

manifest_max_index(){
  local dest="$1"
  awk -F'\t' -v d="$dest" 'BEGIN{m=-1} $0 !~ /^#/ && $1==d && $2+0>m {m=$2+0} END{print m}' "$MANIFEST_FILE"
}

manifest_append(){
  local dest="$1" idx="$2" src="$3" bytes="$4"
  if (( DRY_RUN )); then log "DRY-RUN: would append manifest dest=$dest file=$idx source=$src bytes=$bytes"; return 0; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$dest" "$idx" "$src" "$bytes" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "COPIED" "$SRC_RESOLVED" "$DST_NOREWIND" >> "$MANIFEST_FILE"
}

manifest_set_verify(){
  local dest="$1" idx="$2" state="$3" tmp
  (( DRY_RUN )) && return 0
  tmp="${MANIFEST_FILE}.tmp.$$"
  awk -F'\t' -v OFS='\t' -v d="$dest" -v i="$idx" -v s="$state" '
    /^#/ {print; next}
    $1==d && $2==i {$6=s}
    {print}
  ' "$MANIFEST_FILE" > "$tmp"
  mv -f -- "$tmp" "$MANIFEST_FILE"
  chmod 600 "$MANIFEST_FILE" 2>/dev/null || true
}

manifest_clear_dest(){
  local dest="$1" tmp
  (( DRY_RUN )) && { log "DRY-RUN: would clear manifest rows for dest=$dest"; return 0; }
  tmp="${MANIFEST_FILE}.tmp.$$"
  awk -F'\t' -v d="$dest" '/^#/ || $1!=d' "$MANIFEST_FILE" > "$tmp"
  mv -f -- "$tmp" "$MANIFEST_FILE"
  chmod 600 "$MANIFEST_FILE" 2>/dev/null || true
}

show_manifest(){
  local dest="${1:-}"
  printf '%-14s %-7s %-14s %-14s %-25s %-12s\n' "DEST" "FILE#" "SOURCE" "BYTES" "COPIED_AT" "VERIFY"
  printf '%-14s %-7s %-14s %-14s %-25s %-12s\n' "--------------" "-------" "--------------" "--------------" "-------------------------" "------------"
  awk -F'\t' -v d="$dest" '
    $0 !~ /^#/ && (d=="" || $1==d) {
      printf "%-14s %-7s %-14s %-14s %-25s %-12s\n",$1,$2,$3,$4,$5,$6
    }
  ' "$MANIFEST_FILE"
}

# --------------------------- Wrapper helpers -----------------------------
run_capture(){
  # run_capture OUTFILE command args...
  local outfile="$1"; shift
  local rc
  if (( DRY_RUN )); then
    printf '%s [DRYRUN] ' "$(ts)" | tee -a "$outfile"
    printf '%q ' "$@" | tee -a "$outfile"
    printf '\n' | tee -a "$outfile"
    return 0
  fi
  "$@" 2>&1 | tee -a "$outfile"
  rc=${PIPESTATUS[0]}
  return "$rc"
}

parse_source_volser(){
  local f="$1" v
  v="$(grep -E '^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$' "$f" | tail -n 1 || true)"
  [[ -n "$v" ]] || v="$(grep -Eo 'volume=[A-Za-z0-9._-]+' "$f" | tail -n 1 | cut -d= -f2 || true)"
  printf '%s' "$v"
}

parse_scalar_volser(){
  local f="$1" v
  v="$(sed -nE 's/.*Selected tape:[[:space:]]*\[([^]]+)\].*/\1/p' "$f" | tail -n 1)"
  [[ -n "$v" ]] || v="$(sed -nE 's/.*Scalar i3 reports loaded cartridge:[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | tail -n 1)"
  [[ -n "$v" ]] || v="$(sed -nE 's/.*Selected Tape[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | tail -n 1)"
  printf '%s' "$v"
}

scalar_load_destination(){
  local tmp rc
  if [[ -n "$DEST_LOADED_VOLSER" ]]; then
    valid_volser "$DEST_LOADED_VOLSER" || die 30 "Invalid --dest-loaded VOLSER: $DEST_LOADED_VOLSER"
    DEST_VOLSER="$DEST_LOADED_VOLSER"
    log "Using already loaded Scalar destination VOLSER=$DEST_VOLSER"
    require_online "$DST_RESOLVED"
    return 0
  fi

  if (( DRY_RUN )); then
    DEST_VOLSER="DRYRUNDEST"
    log "DRY-RUN: would load Scalar destination using $SCALAR_OPS load"
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/t2t_scalar_load.XXXXXX")"
  log "Loading Scalar destination using: $SCALAR_OPS load"
  if run_capture "$tmp" "$SCALAR_OPS" load; then
    rc=0
  else
    rc=$?
  fi
  if (( rc != 0 )); then
    rm -f -- "$tmp"
    die 31 "Scalar destination load failed rc=$rc"
  fi
  DEST_VOLSER="$(parse_scalar_volser "$tmp")"
  rm -f -- "$tmp"
  [[ -n "$DEST_VOLSER" ]] || die 32 "Scalar load succeeded but destination VOLSER could not be parsed"
  valid_volser "$DEST_VOLSER" || die 33 "Parsed invalid Scalar destination VOLSER: $DEST_VOLSER"
  ok "Scalar destination loaded: $DEST_VOLSER"
  require_online "$DST_RESOLVED"
}

scalar_unload_destination(){
  log "Unloading Scalar destination VOLSER=$DEST_VOLSER"
  run_cmd "$SCALAR_OPS" unload
}

ts_load_source(){
  local requested="${1:-}" tmp rc actual
  LOADED_SOURCE_VOLSER=""
  if (( DRY_RUN )); then
    LOADED_SOURCE_VOLSER="${requested:-DRYRUNSRC}"
    log "DRY-RUN: would load TS4500 source VOLSER=$LOADED_SOURCE_VOLSER"
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/t2t_ts_load.XXXXXX")"
  if [[ -n "$requested" ]]; then
    log "Loading TS4500 source VOLSER=$requested"
    if run_capture "$tmp" "$TS4500_OPS" load "$requested"; then rc=0; else rc=$?; fi
    if (( rc != 0 )); then rm -f -- "$tmp"; die 40 "TS4500 load failed for $requested rc=$rc"; fi
  else
    log "Loading TS4500 source using automatic selection"
    if run_capture "$tmp" "$TS4500_OPS" load; then rc=0; else rc=$?; fi
    if (( rc != 0 )); then rm -f -- "$tmp"; die 40 "TS4500 automatic load failed rc=$rc"; fi
  fi
  actual="$(parse_source_volser "$tmp")"
  rm -f -- "$tmp"
  [[ -n "$actual" ]] || die 41 "TS4500 load succeeded but source VOLSER could not be parsed"
  if [[ -n "$requested" && "$actual" != "$requested" ]]; then
    die 42 "TS4500 loaded unexpected VOLSER: requested=$requested actual=$actual"
  fi
  LOADED_SOURCE_VOLSER="$actual"
}

ts_probe_source(){
  local vol="$1"
  log "Validating TS4500 source tar archive: $vol"
  run_cmd "$TS4500_OPS" tape-probe "$vol" --entries "$PROBE_ENTRIES" --timeout "$PROBE_TIMEOUT"
}

ts_after_source(){
  local vol="$1"
  case "$SOURCE_AFTER" in
    unload)
      log "Returning source $vol to TS4500 slot"
      run_cmd "$TS4500_OPS" unload "$vol"
      ;;
    export)
      log "Unloading and exporting source $vol to TS4500 I/O slot"
      run_cmd "$TS4500_OPS" unload-export "$vol" --yes
      ;;
    *) die 43 "Invalid source-after mode: $SOURCE_AFTER" ;;
  esac
}

# ------------------------ Tape layout safety -----------------------------
verify_source_single_tape_file(){
  local vol="$1" rc
  (( SKIP_SINGLE_FILE_CHECK )) && {
    warn "Skipping source single-tape-file check for $vol by request"
    return 0
  }

  log "Checking source $vol contains exactly one tape file"
  rewind_tape "$SRC_NOREWIND"
  require_online "$SRC_NOREWIND"

  # Fast-space over the first tape file. If data exists immediately afterward,
  # the source cartridge has a second tape file, which v1.0 intentionally
  # refuses because one dd copy stops at the first filemark.
  if ! run_cmd mt -f "$SRC_NOREWIND" fsf 1; then
    rewind_tape "$SRC_NOREWIND" || true
    die 44 "Unable to fsf over source tape file #0 for $vol"
  fi

  set +e
  peek_current_data "$SRC_NOREWIND"
  rc=$?
  set -e
  rewind_tape "$SRC_NOREWIND"

  case "$rc" in
    0) die 45 "Source $vol contains more than one tape file; refusing partial raw migration" ;;
    1) ok "Source single-file check PASSED: $vol has one tape file followed by logical EOD" ;;
    *) die 46 "Could not safely determine tape-file count for source $vol" ;;
  esac
}

prepare_destination_append_position(){
  local count rc
  count="$(manifest_count "$DEST_VOLSER")"
  log "Destination manifest state: volser=$DEST_VOLSER existing_files=$count"

  if (( count == 0 )); then
    rewind_tape "$DST_NOREWIND"
    require_online "$DST_NOREWIND"

    set +e
    peek_current_data "$DST_NOREWIND"
    rc=$?
    set -e
    rewind_tape "$DST_NOREWIND"

    case "$rc" in
      0)
        if (( OVERWRITE_DEST == 0 )); then
          die 50 "Destination $DEST_VOLSER contains untracked data at BOT; refusing overwrite"
        fi
        (( YES )) || die 51 "--overwrite-destination requires --yes"
        warn "OVERWRITE authorized: existing destination data on $DEST_VOLSER will be destroyed from BOT"
        manifest_clear_dest "$DEST_VOLSER"
        ;;
      1)
        ok "Destination $DEST_VOLSER appears blank at BOT"
        ;;
      *) die 52 "Unable to determine whether destination $DEST_VOLSER is blank" ;;
    esac

    rewind_tape "$DST_NOREWIND"
    return 0
  fi

  # Manifest-managed resume: GNU mt semantics allow rewind + fsf N to position
  # at the beginning of tape file N (the append point after N existing files).
  rewind_tape "$DST_NOREWIND"
  log "Positioning destination for append: rewind + fsf $count"
  run_cmd mt -f "$DST_NOREWIND" fsf "$count" || die 53 "Failed to position destination after $count tape files"

  # Ensure there is no untracked tape file beyond the manifest count.
  set +e
  peek_current_data "$DST_NOREWIND"
  rc=$?
  set -e
  rewind_tape "$DST_NOREWIND"
  run_cmd mt -f "$DST_NOREWIND" fsf "$count" || die 54 "Failed to restore append position after EOD check"

  case "$rc" in
    0) die 55 "Destination $DEST_VOLSER contains data beyond manifest file count=$count; refusing overwrite" ;;
    1) ok "Destination append position verified at logical EOD after tape file #$((count-1))" ;;
    *) die 56 "Unable to validate destination logical EOD" ;;
  esac
}

# --------------------------- Raw stream copy -----------------------------
parse_dd_bytes(){
  local f="$1"
  tr '\r' '\n' < "$f" | awk '$1 ~ /^[0-9]+$/ && $2=="bytes" {b=$1} END{print b+0}'
}

copy_one_tape_file(){
  local srcvol="$1" idx="$2" ddlog start now elapsed next_hb bytes rc

  ddlog="${LOG_DIR}/dd_${srcvol}_to_${DEST_VOLSER}_file${idx}_$(date '+%Y%m%d_%H%M%S').log"

  # The source probe finishes by rewinding to BOT, but explicitly rewind again
  # immediately before the raw copy so the write point is deterministic.
  rewind_tape "$SRC_RESOLVED"
  require_online "$SRC_RESOLVED"
  require_online "$DST_NOREWIND"

  log "RAW COPY BEGIN: source=$srcvol source_device=$SRC_RESOLVED destination=$DEST_VOLSER tape_file=$idx destination_device=$DST_NOREWIND bs=$DD_BS"

  if (( DRY_RUN )); then
    printf '%s [DRYRUN] dd if=%q of=%q bs=%q status=progress\n' "$(ts)" "$SRC_RESOLVED" "$DST_NOREWIND" "$DD_BS"
    manifest_append "$DEST_VOLSER" "$idx" "$srcvol" 0
    return 0
  fi

  start="$(date +%s)"
  next_hb=$((start + HEARTBEAT_SEC))
  set +e
  LC_ALL=C dd if="$SRC_RESOLVED" of="$DST_NOREWIND" bs="$DD_BS" status=progress 2>"$ddlog" &
  local ddpid=$!
  set -e

  while kill -0 "$ddpid" 2>/dev/null; do
    sleep 1
    now="$(date +%s)"
    if (( now >= next_hb )); then
      bytes="$(parse_dd_bytes "$ddlog")"
      elapsed=$((now-start))
      log "[PROGRESS] phase=RAW_COPY elapsed=$(fmt_elapsed "$elapsed") bytes=$bytes human=$(fmt_bytes "$bytes") source=$srcvol destination=$DEST_VOLSER tape_file=$idx dd_pid=$ddpid state=RUNNING"
      next_hb=$((now + HEARTBEAT_SEC))
    fi
  done

  if wait "$ddpid"; then rc=0; else rc=$?; fi

  now="$(date +%s)"
  elapsed=$((now-start))
  bytes="$(parse_dd_bytes "$ddlog")"

  if (( rc != 0 )); then
    err "RAW COPY FAILED: rc=$rc source=$srcvol destination=$DEST_VOLSER tape_file=$idx bytes=$bytes elapsed=$(fmt_elapsed "$elapsed") log=$ddlog"
    tail -n 30 "$ddlog" >&2 || true
    return 60
  fi
  if (( bytes <= 0 )); then
    err "RAW COPY FAILED: zero bytes copied from source=$srcvol; log=$ddlog"
    return 61
  fi

  manifest_append "$DEST_VOLSER" "$idx" "$srcvol" "$bytes"
  ok "RAW COPY SUCCESS: source=$srcvol -> destination=$DEST_VOLSER tape_file=$idx bytes=$bytes ($(fmt_bytes "$bytes")) elapsed=$(fmt_elapsed "$elapsed") log=$ddlog"
}

# -------------------------- Destination verify ---------------------------
verify_one_destination_file(){
  local dest="$1" idx="$2" mode="$3" src="${4:-}" tmpout tmperr rc lines
  tmpout="$(mktemp "${TMPDIR:-/tmp}/t2t_verify_out.XXXXXX")"
  tmperr="$(mktemp "${TMPDIR:-/tmp}/t2t_verify_err.XXXXXX")"

  rewind_tape "$DST_NOREWIND"
  if (( idx > 0 )); then
    run_cmd mt -f "$DST_NOREWIND" fsf "$idx" || {
      rm -f -- "$tmpout" "$tmperr"
      return 70
    }
  fi

  if (( DRY_RUN )); then
    rm -f -- "$tmpout" "$tmperr"
    return 0
  fi

  case "$mode" in
    probe)
      set +e
      timeout --signal=TERM --kill-after=5 "${PROBE_TIMEOUT}s" \
        tar -tvf "$DST_NOREWIND" 2>"$tmperr" | head -n "$PROBE_ENTRIES" >"$tmpout"
      local -a prc=("${PIPESTATUS[@]}")
      set -e
      lines="$(wc -l < "$tmpout" | awk '{print $1}')"
      if (( lines == 0 )) || grep -Eqi 'This does not look like a tar archive|Unexpected EOF|Error is not recoverable|Input/output error|I/O error|Read error' "$tmperr"; then
        printf '%s\n' '--- VERIFY STDERR ---' >&2
        cat "$tmperr" >&2 || true
        rm -f -- "$tmpout" "$tmperr"
        return 71
      fi
      printf '%s\n' "--- DEST VERIFY tape_file=$idx source=${src:-UNKNOWN} ---"
      cat "$tmpout"
      printf '%s\n' '--- END DEST VERIFY ---'
      ok "Destination probe PASSED: dest=$dest tape_file=$idx source=${src:-UNKNOWN} requested=$PROBE_ENTRIES displayed=$lines"
      ;;
    full)
      set +e
      tar -tf "$DST_NOREWIND" > /dev/null 2>"$tmperr"
      rc=$?
      set -e
      if (( rc != 0 )); then
        cat "$tmperr" >&2 || true
        rm -f -- "$tmpout" "$tmperr"
        return 72
      fi
      ok "Destination full tar read PASSED: dest=$dest tape_file=$idx source=${src:-UNKNOWN}"
      ;;
    *) rm -f -- "$tmpout" "$tmperr"; return 73 ;;
  esac

  rm -f -- "$tmpout" "$tmperr"
  return 0
}

verify_destination_manifest(){
  local dest="$1" mode="$2" line idx src failed=0
  [[ "$mode" != "none" ]] || { log "Destination verification skipped (--verify none)"; return 0; }

  log "Verifying destination $dest using manifest mode=$mode"
  while IFS=$'\t' read -r _dest idx src _bytes _time _verify _sdev _ddev; do
    [[ "$_dest" == "$dest" ]] || continue
    if verify_one_destination_file "$dest" "$idx" "$mode" "$src"; then
      manifest_set_verify "$dest" "$idx" "${mode^^}_PASS"
    else
      manifest_set_verify "$dest" "$idx" "${mode^^}_FAIL"
      failed=1
      break
    fi
  done < <(grep -v '^#' "$MANIFEST_FILE")

  rewind_tape "$DST_NOREWIND" || true
  (( failed == 0 )) || return 74
  ok "Destination verification PASSED for all manifest tape files: dest=$dest mode=$mode"
}

# ------------------------------- Commands --------------------------------
cmd_status(){
  require_root
  need_cmd mt
  resolve_devices
  printf 'Tape-to-Tape Migration v%s\n' "$VERSION"
  printf 'TS4500 wrapper      : %s\n' "$TS4500_OPS"
  printf 'Scalar wrapper      : %s\n' "$SCALAR_OPS"
  printf 'Source rewind       : %s -> %s\n' "$SRC_TAPE_LINK" "$SRC_RESOLVED"
  printf 'Source non-rewind   : %s\n' "$SRC_NOREWIND"
  printf 'Dest rewind/link    : %s -> %s\n' "$DST_TAPE_LINK" "$DST_RESOLVED"
  printf 'Dest non-rewind     : %s\n' "$DST_NOREWIND"
  printf 'Manifest            : %s\n' "$MANIFEST_FILE"
  printf 'Verify mode         : %s\n' "$VERIFY_MODE"
  printf '\n[Source mt status]\n'
  mt -f "$SRC_RESOLVED" status 2>&1 || true
  printf '\n[Destination mt status]\n'
  mt -f "$DST_RESOLVED" status 2>&1 || true
}

cmd_manifest(){ show_manifest "${1:-}"; }

cmd_verify(){
  local dest="$1"
  [[ -n "$dest" ]] || die 80 "verify requires DEST_VOLSER"
  valid_volser "$dest" || die 81 "Invalid DEST_VOLSER: $dest"
  (( $(manifest_count "$dest") > 0 )) || die 82 "No manifest entries for destination $dest"
  resolve_devices
  require_online "$DST_RESOLVED"
  DEST_VOLSER="$dest"
  verify_destination_manifest "$dest" "$VERIFY_MODE" || die 83 "Destination verification failed; cartridge left loaded"
}

cmd_migrate(){
  local requested actual idx existing total rc
  (( YES )) || die 90 "migrate writes tape media; add --yes"
  require_root
  need_exec "$TS4500_OPS"
  need_exec "$SCALAR_OPS"
  need_cmd mt; need_cmd dd; need_cmd tar; need_cmd timeout
  resolve_devices

  RUN_LOG="${LOG_DIR}/migrate_$(date '+%Y%m%d_%H%M%S').log"
  exec > >(tee -a "$RUN_LOG") 2>&1

  log "===== Tape-to-Tape Migration v$VERSION BEGIN ====="
  log "Source wrapper=$TS4500_OPS"
  log "Scalar wrapper=$SCALAR_OPS"
  log "Source device=$SRC_RESOLVED source_norewind=$SRC_NOREWIND"
  log "Destination device=$DST_RESOLVED destination_norewind=$DST_NOREWIND"
  log "verify=$VERIFY_MODE source_after=$SOURCE_AFTER dest_after=$DEST_AFTER"

  scalar_load_destination
  prepare_destination_append_position

  existing="$(manifest_count "$DEST_VOLSER")"
  idx="$existing"

  if (( ${#SOURCE_VOLS[@]} == 0 )); then
    SOURCE_VOLS=("")
  fi

  for requested in "${SOURCE_VOLS[@]}"; do
    ts_load_source "$requested"
    actual="$LOADED_SOURCE_VOLSER"
    ok "TS4500 source loaded: $actual"

    # Source probe proves the first tape file is a readable tar archive and
    # leaves the source tape at BOT.
    ts_probe_source "$actual"
    verify_source_single_tape_file "$actual"

    # Restore destination append point because source safety checks do not
    # touch destination, but explicit positioning before every copy is cheap
    # insurance against operator/driver position changes.
    rewind_tape "$DST_NOREWIND"
    if (( idx > 0 )); then
      run_cmd mt -f "$DST_NOREWIND" fsf "$idx" || die 91 "Failed to position destination at tape file index=$idx"
    fi

    if copy_one_tape_file "$actual" "$idx"; then rc=0; else rc=$?; fi
    if (( rc != 0 )); then
      err "Migration stopped. Source $actual and destination $DEST_VOLSER remain loaded for investigation."
      exit "$rc"
    fi

    # Only after the destination tape file and manifest are safely written do
    # we return/export the source cartridge.
    ts_after_source "$actual"
    idx=$((idx+1))

    total="$(manifest_bytes "$DEST_VOLSER")"
    ok "Destination logical payload so far: dest=$DEST_VOLSER files=$idx bytes=$total ($(fmt_bytes "$total"))"
    log "NOTE: logical payload bytes are not an authoritative LTO remaining-capacity measurement because drive compression may apply."
  done

  if ! verify_destination_manifest "$DEST_VOLSER" "$VERIFY_MODE"; then
    err "Destination verification failed. Scalar cartridge $DEST_VOLSER remains loaded."
    exit 92
  fi

  case "$DEST_AFTER" in
    keep)
      ok "Migration completed; Scalar destination $DEST_VOLSER left loaded by policy"
      ;;
    unload)
      scalar_unload_destination
      ok "Migration completed; Scalar destination $DEST_VOLSER unloaded"
      ;;
    *) die 93 "Invalid dest-after mode: $DEST_AFTER" ;;
  esac

  total="$(manifest_bytes "$DEST_VOLSER")"
  printf '\n============================================================\n'
  printf ' Tape-to-Tape Migration Summary\n'
  printf '============================================================\n'
  printf ' Destination VOLSER : %s\n' "$DEST_VOLSER"
  printf ' Tape Files         : %s\n' "$(manifest_count "$DEST_VOLSER")"
  printf ' Logical Bytes      : %s (%s)\n' "$total" "$(fmt_bytes "$total")"
  printf ' Verify Mode        : %s\n' "$VERIFY_MODE"
  printf ' Destination After  : %s\n' "$DEST_AFTER"
  printf ' Manifest           : %s\n' "$MANIFEST_FILE"
  printf ' Run Log            : %s\n' "$RUN_LOG"
  printf '============================================================\n'
  show_manifest "$DEST_VOLSER"
  log "===== Tape-to-Tape Migration COMPLETED ====="
}

# ----------------------------- Arguments ---------------------------------
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    status|manifest|migrate|verify)
      [[ -z "$COMMAND" ]] || die 2 "Only one command may be specified"
      COMMAND="$1"; shift
      ;;
    --ts-ops) [[ $# -ge 2 ]] || die 2 "--ts-ops requires PATH"; TS4500_OPS="$2"; shift 2 ;;
    --scalar-ops) [[ $# -ge 2 ]] || die 2 "--scalar-ops requires PATH"; SCALAR_OPS="$2"; shift 2 ;;
    --src-device) [[ $# -ge 2 ]] || die 2 "--src-device requires DEV"; SRC_TAPE_LINK="$2"; shift 2 ;;
    --src-norewind) [[ $# -ge 2 ]] || die 2 "--src-norewind requires DEV"; SRC_NOREWIND="$2"; shift 2 ;;
    --dst-device) [[ $# -ge 2 ]] || die 2 "--dst-device requires DEV"; DST_TAPE_LINK="$2"; shift 2 ;;
    --dst-norewind) [[ $# -ge 2 ]] || die 2 "--dst-norewind requires DEV"; DST_NOREWIND="$2"; shift 2 ;;
    --dest-loaded) [[ $# -ge 2 ]] || die 2 "--dest-loaded requires VOLSER"; DEST_LOADED_VOLSER="$2"; shift 2 ;;
    --source-after) [[ $# -ge 2 ]] || die 2 "--source-after requires MODE"; SOURCE_AFTER="$2"; shift 2 ;;
    --dest-after) [[ $# -ge 2 ]] || die 2 "--dest-after requires MODE"; DEST_AFTER="$2"; shift 2 ;;
    --verify) [[ $# -ge 2 ]] || die 2 "--verify requires MODE"; VERIFY_MODE="$2"; shift 2 ;;
    --probe-entries) [[ $# -ge 2 ]] || die 2 "--probe-entries requires N"; PROBE_ENTRIES="$2"; shift 2 ;;
    --probe-timeout) [[ $# -ge 2 ]] || die 2 "--probe-timeout requires SEC"; PROBE_TIMEOUT="$2"; shift 2 ;;
    --heartbeat-sec) [[ $# -ge 2 ]] || die 2 "--heartbeat-sec requires SEC"; HEARTBEAT_SEC="$2"; shift 2 ;;
    --dd-bs) [[ $# -ge 2 ]] || die 2 "--dd-bs requires SIZE"; DD_BS="$2"; shift 2 ;;
    --manifest) [[ $# -ge 2 ]] || die 2 "--manifest requires FILE"; MANIFEST_FILE="$2"; shift 2 ;;
    --overwrite-destination) OVERWRITE_DEST=1; shift ;;
    --skip-single-file-check) SKIP_SINGLE_FILE_CHECK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    -V|--version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while (( $# > 0 )); do ARGS+=("$1"); shift; done ;;
    -*) die 2 "Unknown option: $1" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage; exit 2; }
[[ "$HEARTBEAT_SEC" =~ ^[1-9][0-9]*$ ]] || die 2 "heartbeat-sec must be positive integer"
[[ "$PROBE_ENTRIES" =~ ^[1-9][0-9]*$ ]] || die 2 "probe-entries must be positive integer"
[[ "$PROBE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 2 "probe-timeout must be positive integer"
case "$VERIFY_MODE" in none|probe|full) ;; *) die 2 "Invalid verify mode: $VERIFY_MODE" ;; esac
case "$SOURCE_AFTER" in unload|export) ;; *) die 2 "Invalid source-after: $SOURCE_AFTER" ;; esac
case "$DEST_AFTER" in keep|unload) ;; *) die 2 "Invalid dest-after: $DEST_AFTER" ;; esac

init_dirs

case "$COMMAND" in
  status)
    acquire_lock
    cmd_status
    ;;
  manifest)
    cmd_manifest "${ARGS[0]:-}"
    ;;
  verify)
    acquire_lock
    [[ ${#ARGS[@]} -eq 1 ]] || die 2 "verify requires exactly one DEST_VOLSER"
    cmd_verify "${ARGS[0]}"
    ;;
  migrate)
    acquire_lock
    SOURCE_VOLS=("${ARGS[@]}")
    for v in "${SOURCE_VOLS[@]}"; do valid_volser "$v" || die 2 "Invalid SOURCE_VOLSER: $v"; done
    cmd_migrate
    ;;
esac
