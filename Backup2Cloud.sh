#!/usr/bin/env bash
set -u
set -o pipefail

umask 002

# ==============================================================================
# Backup2Cloud_auto.sh
# Purpose:
#   1. Run OP control checks
#   2. Verify OPdump source files before backup
#   3. Create backup by SSH using streaming pipeline:
#        find + tar + zstd + gpg passphrase + gpg public key
#   4. Verify final GPG encrypted packet is readable
#   5. Rsync generated files to taifex-bk:/alldata
#   6. Send mail result
#
# Usage:
#   ./Backup2Cloud_auto.sh daily
#   ./Backup2Cloud_auto.sh monthly
#   ./Backup2Cloud_auto.sh ondemand <tag>
#
#   ./Backup2Cloud_auto.sh Z0300 daily
#   ./Backup2Cloud_auto.sh Z0300 monthly
#   ./Backup2Cloud_auto.sh Z0300 ondemand <tag>
#
#   ./Backup2Cloud_auto.sh Z0300AH daily
#   ./Backup2Cloud_auto.sh Z0300AH monthly
#   ./Backup2Cloud_auto.sh Z0300AH ondemand <tag>
# ==============================================================================

# ===============================
# ENVIRONMENT
# ===============================
PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH

. /sybase/SYBASE.sh &>/dev/null || true

# ===============================
# SCRIPT META
# ===============================
SCRIPT_NAME="$(basename "$0")"
SCRIPT_START_TS="$(date +%s)"

# ===============================
# BASIC CONFIGURATION
# ===============================
OPF_UTIL="/aprun/shell/opf_util.sh"

#
# GPG SETTINGS
#
# Final encryption flow:
#   tar stream -> zstd -> GPG symmetric/passphrase -> GPG public-key/RSA encrypt -> hidden encrypted tmp
#
# Final file name example:
#   APDATA_xxx_YYYYMMDD_HHMMSS.zst.signed
#
# SECURITY NOTE:
#   Your passphrase has appeared in command output before.
#   For production, rotate it and prefer loading it from a protected root-owned file.
#
GPG_PASSPHRASE="${GPG_PASSPHRASE:-Taifex@Backup2Cloud@xo^_^ox}"
GPG_RECIPIENT="${GPG_RECIPIENT:-backup2cloud-encrypt@taifex.com.tw}"
#GPG_RECIPIENT="${GPG_RECIPIENT:-DCFC1E1BC8ECF64BA9D5EC5BA094333141C3DE57}"

# Optional: force a specific signing key.
# Leave empty to let GPG use the default secret key on the remote backup source host.
# Example:
#   export GPG_SIGNER="backup2cloud-sign@taifex.com.tw"
GPG_SIGNER="${GPG_SIGNER:-backup2cloud-encrypt@taifex.com.tw}"

# Signing key passphrase.
# If your signing private key uses the same passphrase, keep this default.
GPG_SIGN_PASSPHRASE="${GPG_SIGN_PASSPHRASE:-${GPG_PASSPHRASE}}"

# Embedded signing after final encryption.
# This creates a GPG signed file that contains the encrypted backup file.
# Verification uses: gpg --verify final_file.signed
GPG_SIGN_ENABLED="${GPG_SIGN_ENABLED:-yes}"
GPG_SIGN_ARMOR="${GPG_SIGN_ARMOR:-no}"

# Final output suffix. Do not use .zst.sym.rsa.gpg anymore.
GPG_FINAL_SUFFIX="${GPG_FINAL_SUFFIX:-.signed}"

#
# Compression speed setting
#
# Recommended:
#   ZSTD_ARGS="-T0 -1"        fast default
#   ZSTD_ARGS="-T0 --fast=3"  faster, larger output
#   ZSTD_ARGS="-T0 -3"        slower, better compression
#
ZSTD_ARGS="${ZSTD_ARGS:--T0 -1}"

DATE_YMD="$(date +%Y%m%d)"
DATE_TS="$(date +%Y%m%d_%H%M%S)"

CHOST="taifex-bk"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_DEST="/alldata"
OPDUMP_SRC="/data_stored"

# DB credentials
iUSERNAME="${iUSERNAME:-apusr1}"
iPASSWORD="${iPASSWORD:-1qaz2wsx}"

SrvName="FUTURES"
DbName="futures"
iDATABASE="futures"
iSERVER="FUTURES"

# max concurrent jobs
PARALLEL_JOBS=20

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=60
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=no
)

# ===============================
# ARGUMENT PARSING
# ===============================
OPNO="Z0300"
SCHEDULE="daily"
TAG=""

case "${1:-}" in
  daily|monthly)
    OPNO="Z0300"
    SCHEDULE="$1"
    TAG=""
    ;;
  ondemand)
    OPNO="Z0300"
    SCHEDULE="$1"
    TAG="${2:-}"
    ;;
  Z0300|Z0300AH)
    OPNO="$1"
    SCHEDULE="${2:-daily}"
    TAG="${3:-}"
    ;;
  "")
    echo "Usage:"
    echo "  $0 daily"
    echo "  $0 monthly"
    echo "  $0 ondemand <tag>"
    echo "  $0 Z0300 daily"
    echo "  $0 Z0300 monthly"
    echo "  $0 Z0300 ondemand <tag>"
    echo "  $0 Z0300AH daily"
    echo "  $0 Z0300AH monthly"
    echo "  $0 Z0300AH ondemand <tag>"
    exit 1
    ;;
  *)
    echo "Invalid argument: $1"
    echo "Usage:"
    echo "  $0 daily"
    echo "  $0 monthly"
    echo "  $0 ondemand <tag>"
    echo "  $0 Z0300 daily"
    echo "  $0 Z0300AH daily"
    exit 1
    ;;
esac

JobID="${OPNO}"
BASE_OPNO="${OPNO%AH}"

# ===============================
# TEMP LOGGING FOR EARLY ERRORS
# ===============================
early_log_err() {
  echo "[$(date '+%F %T')] [ERROR] $*" >&2
}

# ===============================
# ADJUST PATHS BASED ON OPNO
# ===============================
case "$BASE_OPNO" in
  Z0300)
    if [[ "$OPNO" == *AH ]]; then
      SUFFIX="AH"
      JobID="Z0300AH"

      SrvName="FUTURESAH"
      iSERVER="FUTURESAH"

      BKROOT="/data_bkah/os_config/alldata"
      LOGDIR="/data_bkah/os_config/logs"

      OPDUMP_SRC="/data_storedah"

#      mapfile -t bk_old < <(
#        ssh "changer@${CHOST}" '
#          find /data_oldah -maxdepth 1 -mindepth 1 -type d -mtime -14 \
#            -regextype posix-extended -regex ".*/[0-9]{8}" -printf "%f\0" 2>/dev/null |
#          sort -rz |
#          while IFS= read -r -d "" dir; do
#            if find "/data_oldah/$dir" -maxdepth 1 -type f \( -name "OPdump*" \) -size +200000c -print -quit 2>/dev/null | grep -q .; then
#              echo "/data_oldah/$dir"
#              break
#            fi
#          done
#        '
#      )

#      [[ ${#bk_old[@]} -eq 0 ]] && {
#        early_log_err "[$JobID]: Nothing to backup"
#        exit 1
#      }

#      OPDUMP_SRC="${bk_old[@]}"
      OPDUMP_MODE="AH"
    else
      SUFFIX=""
      JobID="Z0300"

      SrvName="FUTURES"
      iSERVER="FUTURES"

      BKROOT="/data_bk/os_config/alldata"
      LOGDIR="/data_bk/os_config/logs"

      OPDUMP_SRC="/data_stored"

#      mapfile -t bk_old < <(
#        ssh "changer@${CHOST}" '
#          find /data_old -maxdepth 1 -mindepth 1 -type d -mtime -14 \
#            -regextype posix-extended -regex ".*/[0-9]{8}" -printf "%f\0" 2>/dev/null |
#          sort -rz |
#          while IFS= read -r -d "" dir; do
#            if find "/data_old/$dir" -maxdepth 1 -type f \( -name "OPdump*" \) -size +200000c -print -quit 2>/dev/null | grep -q .; then
#              echo "/data_old/$dir"
#              break
#            fi
#          done
#        '
#      )

#      [[ ${#bk_old[@]} -eq 0 ]] && {
#        early_log_err "[$JobID]: Nothing to backup"
#        exit 1
#      }

#      OPDUMP_SRC="${bk_old[@]}"
      OPDUMP_MODE="REGULAR"
    fi

    OPNO="$BASE_OPNO"
    DbName="futures"
    iDATABASE="futures"
    ;;
  *)
    echo "No backup defined for this OPNO."
    exit 0
    ;;
esac

# ===============================
# DESTINATION
# ===============================
case "${SCHEDULE}" in
  daily)
    DESTDIR="${BKROOT}/daily/${DATE_YMD}"
    RUN_NAME="daily"
    ;;
  monthly)
    DESTDIR="${BKROOT}/monthly/${DATE_YMD}"
    RUN_NAME="monthly"
    ;;
  ondemand)
    if [[ -z "${TAG}" ]]; then
      echo "Usage: $0 ${JobID} ondemand <tag>"
      exit 1
    fi
    SAFE_TAG="$(echo "${TAG}" | tr -cs '[:alnum:]_.-' '_')"
    DESTDIR="${BKROOT}/ondemand/${DATE_TS}_${SAFE_TAG}"
    RUN_NAME="ondemand"
    ;;
  *)
    echo "Usage:"
    echo "  $0 daily"
    echo "  $0 monthly"
    echo "  $0 ondemand <tag>"
    echo "  $0 Z0300 daily"
    echo "  $0 Z0300AH daily"
    exit 1
    ;;
esac

mkdir -p "${DESTDIR}" "${LOGDIR}"
chmod -R 775 "${DESTDIR}" "${LOGDIR}"
chown -R changer:op "${DESTDIR}" "${LOGDIR}"
LOGFILE="${LOGDIR}/backup_${RUN_NAME}_${DATE_TS}.log"

# ===============================
# MAIL SETTINGS
# ===============================
MAIL_HEADER="[板橋交易] ${JobID} Cloud Migration of Core Data Notice"
SUBJECT="[板橋交易] ${JobID} Cloud Migration of Core Data Notice"
XTAG="[板橋交易] ${JobID} Cloud Migration of Core Data Notice"

MAIL_FROM="sysalert@taifex.com.tw"
MAIL_TO="sys-linux@taifex.com.tw"
MAIL_CC="sys-dba@taifex.com.tw"
MAIL_BCC="taifexop@taifex.com.tw"

# ===============================
# LOGGING FUNCTIONS
# ===============================
log() {
  local level="$1"
  shift

  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  local msg="[$ts] [$level] $*"

  echo "$msg" | tee -a "$LOGFILE"

  for port in 9911; do
    {
      echo "📦 $msg" | /usr/local/bin/socat -t 3 -T 5 - TCP:192.168.110.121:$port
    } >/dev/null 2>&1 &
  done

  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    {
      echo "⚠ $msg" | /usr/local/bin/socat -t 3 -T 5 - TCP:192.168.110.121:9966
      echo "⚠ $msg" | mail -r sysalert@taifex.com.tw -s "⚠  $MAIL_HEADER - $level - $msg" -a "$LOGFILE" sys-linux@taifex.com.tw
    } >/dev/null 2>&1 &
  fi
}

log_info(){ log INFO "$*"; }
log_ok(){ log OK "$*"; }
log_warn(){ log WARN "$*"; }
log_err(){ log ERROR "$*"; }

send_result_mail() {
  local result="$1"
  local elapsed=$(( $(date +%s) - ${SCRIPT_START_TS:-$(date +%s)} ))
  local color
  local subject="${MAIL_HEADER} - [${JobID}] - ${result}"

  if [[ "$result" == "OK" ]]; then
    color="#28a745"
  else
    color="#dc3545"
  fi

  local html_body
  html_body="$(cat <<HTML
<html><body style="font-family:monospace;font-size:13px;">
<h3 style="color:${color};">${subject}</h3>
<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse;">
  <tr><th>JobID</th><td>${JobID}</td></tr>
  <tr><th>Schedule</th><td>${RUN_NAME}</td></tr>
  <tr><th>Date</th><td>${DATE_TS}</td></tr>
  <tr><th>Result</th><td style="color:${color};font-weight:bold;">${result}</td></tr>
  <tr><th>Total jobs</th><td>${TOTAL_JOBS}</td></tr>
  <tr><th>OK jobs</th><td>${OK_JOBS}</td></tr>
  <tr><th>FAIL jobs</th><td>${FAIL_JOBS}</td></tr>
  <tr><th>Elapsed</th><td>${elapsed}s</td></tr>
  <tr><th>Log file</th><td>${LOGFILE}</td></tr>
</table>
<p>See attached log for details.</p>
</body></html>
HTML
)"

  if ! /usr/local/bin/sendEmail \
      -s 192.168.169.232 \
      -o tls=no \
      -o message-charset=utf-8 \
      -o message-content-type=html \
      -t "${MAIL_TO}" \
      -f "${MAIL_FROM}" \
      -l /var/log/sendEmail \
      -a "${LOGFILE}" \
      -u "${SUBJECT} - [${JobID}] - ${result}" \
      -m "${html_body}"
  then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Failed to send result mail: ${result}" >> "${LOGFILE}"
    return 1
  fi

  return 0
}

FAILED=0
TOTAL_JOBS=0
OK_JOBS=0
FAIL_JOBS=0

declare -A JOB_LABELS=()
declare -A JOB_HOSTS=()
declare -A JOB_OUTFILES=()

# ==============================================================================
# OPDUMP SOURCE FILE CHECK
# ==============================================================================
check_opdump_files() {
  local label="$1"
  local host="$2"
  local src_path="$3"
  local mode="$4"

  local remote_cmd=""

  case "$mode" in
    REGULAR)
      remote_cmd="
        set -u
        failed=0

        check_count() {
          type_name=\"\$1\"
          pattern=\"\$2\"
          expect=\"\$3\"

          cnt=\$(find '$src_path' -maxdepth 1 -type f -name \"\$pattern\" 2>/dev/null | wc -l)

          if [ \"\$cnt\" -ne \"\$expect\" ]; then
            echo \"[ERROR] $label \$type_name count abnormal: expected=\$expect actual=\$cnt pattern=\$pattern\"
            failed=1
          else
            echo \"[OK] $label \$type_name count=\$cnt\"
          fi
        }

        check_not_empty() {
          pattern=\"\$1\"
          find '$src_path' -maxdepth 1 -type f -name \"\$pattern\" 2>/dev/null | while read -r f; do
            if [ ! -s \"\$f\" ]; then
              echo \"[ERROR] $label empty file: \$f\"
              exit 10
            else
              size=\$(stat -c '%s' \"\$f\")
              mtime=\$(stat -c '%y' \"\$f\" | cut -d'.' -f1)
              echo \"[OK] $label file=\$f size=\$size mtime=\$mtime\"
            fi
          done
        }

        if [ ! -d '$src_path' ]; then
          echo '[ERROR] $label directory not found: $src_path'
          exit 1
        fi

        check_count FUTURES '*OPdump*FUTURES*' 3
        check_count OPTIONS '*OPdump*OPTIONS*' 3
        check_count SIRS    '*OPdump*SIRS*'    2

        check_not_empty '*OPdump*FUTURES*' || failed=1
        check_not_empty '*OPdump*OPTIONS*' || failed=1
        check_not_empty '*OPdump*SIRS*'    || failed=1

        exit \$failed
      "
      ;;

    AH)
      remote_cmd="
        set -u
        failed=0

        check_count() {
          type_name=\"\$1\"
          pattern=\"\$2\"
          expect=\"\$3\"

          cnt=\$(find '$src_path' -maxdepth 1 -type f -name \"\$pattern\" 2>/dev/null | wc -l)

          if [ \"\$cnt\" -ne \"\$expect\" ]; then
            echo \"[ERROR] $label \$type_name count abnormal: expected=\$expect actual=\$cnt pattern=\$pattern\"
            failed=1
          else
            echo \"[OK] $label \$type_name count=\$cnt\"
          fi
        }

        check_not_empty() {
          pattern=\"\$1\"
          find '$src_path' -maxdepth 1 -type f -name \"\$pattern\" 2>/dev/null | while read -r f; do
            if [ ! -s \"\$f\" ]; then
              echo \"[ERROR] $label empty file: \$f\"
              exit 10
            else
              size=\$(stat -c '%s' \"\$f\")
              mtime=\$(stat -c '%y' \"\$f\" | cut -d'.' -f1)
              echo \"[OK] $label file=\$f size=\$size mtime=\$mtime\"
            fi
          done
        }

        if [ ! -d '$src_path' ]; then
          echo '[ERROR] $label directory not found: $src_path'
          exit 1
        fi

        check_count FUTURESAH '*OPdumpAH*FUTURESAH*' 2
        check_count OPTIONSAH '*OPdumpAH*OPTIONSAH*' 2
        check_count SIRSAH    '*OPdumpAH*SIRSAH*'    2

        check_not_empty '*OPdumpAH*FUTURESAH*' || failed=1
        check_not_empty '*OPdumpAH*OPTIONSAH*' || failed=1
        check_not_empty '*OPdumpAH*SIRSAH*'    || failed=1

        exit \$failed
      "
      ;;

    *)
      log_warn "Invalid OPdump check mode: $mode"
      FAILED=1
      return 1
      ;;
  esac

  log_info "Checking OPdump source files: ${label} on ${host}:${src_path}"

  if ssh "${SSH_OPTS[@]}" "changer@${host}" "${remote_cmd}" | tee -a "${LOGFILE}"; then
    log_ok "OPdump source check OK: ${label}"
    return 0
  else
    log_err "OPdump source check FAILED: ${label}"
    FAILED=1
    return 1
  fi
}

# ==============================================================================
# JOB CONTROL
# ==============================================================================
wait_for_slot() {
  while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
    sleep 1
  done
}

run_ssh_backup() {
  local label="$1"
  local host="$2"
  local src_path="$3"
  local outfile="$4"
  local exclude_old="${5:-0}"
  local mode="${6:-dir}"

  (
    printf '[%s] START %s on %s -> %s%s\n' "$(date '+%F %T')" "${label}" "${host}" "${outfile}" "${GPG_FINAL_SUFFIX}" >> "${LOGFILE}"

    if ssh "${SSH_OPTS[@]}" "changer@${host}" bash -s -- \
      "${src_path}" \
      "${outfile}" \
      "${exclude_old}" \
      "${mode}" \
      "${GPG_PASSPHRASE}" \
      "${GPG_RECIPIENT}" \
      "${GPG_SIGN_ENABLED}" \
      "${GPG_SIGNER}" \
      "${GPG_SIGN_PASSPHRASE}" \
      "${GPG_SIGN_ARMOR}" \
      "${GPG_FINAL_SUFFIX}" \
      "${ZSTD_ARGS}" <<'REMOTE_SCRIPT'
set -euo pipefail

src_path="$1"
outfile="$2"
exclude_old="$3"
mode="$4"
passphrase="$5"
gpg_recipient="$6"
gpg_sign_enabled="$7"
gpg_signer="$8"
gpg_sign_passphrase="$9"
gpg_sign_armor="${10}"
gpg_final_suffix="${11}"
zstd_args="${12}"

umask 002

finalfile="${outfile}${gpg_final_suffix}"
enc_tmp="$(dirname "${finalfile}")/.${finalfile##*/}.encrypted.tmp.$$"
signed_tmp="${finalfile}.tmp.$$"

cleanup() {
  rm -f "${enc_tmp}" "${signed_tmp}"
}
trap cleanup EXIT

mkdir -p "$(dirname "${finalfile}")"

# Stream: tar -> zstd -> GPG symmetric -> GPG public-key encrypt -> hidden encrypted temp file.
encrypt_stream_to_tmp() {
  zstd ${zstd_args} -c |
  gpg --batch --yes \
      --no-symkey-cache \
      --pinentry-mode loopback \
      --passphrase "${passphrase}" \
      --symmetric \
      --cipher-algo AES256 \
      --compress-algo none |
  gpg --batch --yes \
      --encrypt \
      --recipient "${gpg_recipient}" \
      --trust-model always \
      --compress-algo none \
      --output "${enc_tmp}"
}

case "${mode}" in
  dir)
    if [[ "${exclude_old}" -eq 1 ]]; then
      find "${src_path}" -type f -printf '%P\0' |
      tar -C "${src_path}" \
          --exclude='*/old*' \
          --ignore-failed-read \
          --null -T - -cf - 2>/dev/null |
      encrypt_stream_to_tmp
    else
      find "${src_path}" -type f -mtime -1 -printf '%P\0' |
      tar -C "${src_path}" \
          --ignore-failed-read \
          --null -T - -cf - 2>/dev/null |
      encrypt_stream_to_tmp
    fi
    ;;

  files_in_dir_REGULAR)
    find "${src_path}" -maxdepth 1 -type f \
      \( -name '*OPdump*FUTURES*' -o -name '*OPdump*OPTIONS*' -o -name '*OPdump*SIRS*' \) \
      -printf '%P\0' |
    tar -C "${src_path}" \
        --ignore-failed-read \
        --null -T - -cf - 2>/dev/null |
    encrypt_stream_to_tmp
    ;;

  files_in_dir_AH)
    find "${src_path}" -maxdepth 1 -type f \
      \( -name '*OPdumpAH*FUTURESAH*' -o -name '*OPdumpAH*OPTIONSAH*' -o -name '*OPdumpAH*SIRSAH*' \) \
      -printf '%P\0' |
    tar -C "${src_path}" \
        --ignore-failed-read \
        --null -T - -cf - 2>/dev/null |
    encrypt_stream_to_tmp
    ;;

  *)
    echo "[CRIT] invalid mode=${mode}" >&2
    exit 1
    ;;
esac

verify_gpg_packet() {
  local file_to_check="$1"
  local pkt_log="${file_to_check}.packet_check.log.$$"
  local tmp_gnupg=""

  if [[ ! -s "${file_to_check}" ]]; then
    echo "[CRIT] encrypted temp file is missing or empty: ${file_to_check}" >&2
    return 1
  fi

  tmp_gnupg="$(mktemp -d)" || return 1
  chmod 700 "${tmp_gnupg}" || {
    rm -rf "${tmp_gnupg}"
    return 1
  }

  # Use empty GNUPGHOME to avoid local secret-key passphrase prompt.
  # We only check packet structure here, not decrypt content.
  GNUPGHOME="${tmp_gnupg}" \
  gpg --batch --yes --list-packets "${file_to_check}" >"${pkt_log}" 2>&1 || true

  rm -rf "${tmp_gnupg}"

  if ! grep -Eq 'pubkey[[:space:]]+enc[[:space:]]+packet' "${pkt_log}"; then
    echo "[CRIT] GPG packet check failed: pubkey encrypted packet not found: ${file_to_check}" >&2
    echo "[CRIT] packet debug output:" >&2
    sed -n '1,80p' "${pkt_log}" >&2 || true
    rm -f "${pkt_log}"
    return 1
  fi

  rm -f "${pkt_log}"
  return 0
}


sign_embedded_file() {
  local input_file="$1"
  local output_file="$2"
  local sign_identity_args=()
  local armor_args=()

  test -s "${input_file}"

  if [[ -n "${gpg_signer}" ]]; then
    sign_identity_args=(--local-user "${gpg_signer}")
  fi

  if [[ "${gpg_sign_armor}" == "yes" ]]; then
    armor_args=(--armor)
  fi

  gpg --batch --yes \
      --pinentry-mode loopback \
      --passphrase "${gpg_sign_passphrase}" \
      "${sign_identity_args[@]}" \
      --sign \
      "${armor_args[@]}" \
      --output "${output_file}" \
      "${input_file}"
}

verify_embedded_signature() {
  local signed_file="$1"

  test -s "${signed_file}"

  # This verifies the embedded signature of the signed encrypted file.
  # It does not need the RSA decrypt private key, but it needs the signer public key.
  gpg --batch --yes --verify "${signed_file}"
}

verify_gpg_packet "${enc_tmp}" || {
  echo "[CRIT] encrypted GPG packet verification failed: ${enc_tmp}" >&2
  exit 1
}

echo "[OK] encrypted GPG packet verification passed: ${enc_tmp}"

if [[ "${gpg_sign_enabled}" == "yes" ]]; then
  sign_embedded_file "${enc_tmp}" "${signed_tmp}" || {
    echo "[CRIT] embedded GPG signing failed: ${enc_tmp}" >&2
    exit 1
  }

  verify_embedded_signature "${signed_tmp}" || {
    echo "[CRIT] final embedded signature verification failed: ${signed_tmp}" >&2
    exit 1
  }

  mv -f "${signed_tmp}" "${finalfile}"
  rm -f "${enc_tmp}"

  test -s "${finalfile}"
  test ! -f "${enc_tmp}"

  trap - EXIT
  echo "[OK] Streaming backup, encryption, and signing completed: ${finalfile}"
else
  mv -f "${enc_tmp}" "${finalfile}"
  test -s "${finalfile}"

  trap - EXIT
  echo "[WARN] GPG signing disabled; encrypted file kept without embedded signature: ${finalfile}"
fi
REMOTE_SCRIPT
    then
      printf '[%s] OK    %s on %s signed=%s%s\n' "$(date '+%F %T')" "${label}" "${host}" "${outfile}" "${GPG_FINAL_SUFFIX}" >> "${LOGFILE}"
      exit 0
    else
      printf '[%s] FAIL  %s on %s\n' "$(date '+%F %T')" "${label}" "${host}" >> "${LOGFILE}"
      exit 1
    fi
  ) &

  local pid=$!
  JOB_LABELS["${pid}"]="${label}"
  JOB_HOSTS["${pid}"]="${host}"
  JOB_OUTFILES["${pid}"]="${outfile}${GPG_FINAL_SUFFIX}"
  TOTAL_JOBS=$((TOTAL_JOBS + 1))
}

wait_all_jobs() {
  local pid

  for pid in "${!JOB_LABELS[@]}"; do
    if wait "${pid}"; then
      OK_JOBS=$((OK_JOBS + 1))
    else
      FAIL_JOBS=$((FAIL_JOBS + 1))
      FAILED=1
      log_info "VERIFY FAIL ${JOB_LABELS[$pid]} on ${JOB_HOSTS[$pid]} -> ${JOB_OUTFILES[$pid]}"
    fi
  done
}

submit_dir_backup() {
  local label="$1"
  local host="$2"
  local src_path="$3"
  local outfile_base="$4"
  local exclude_old="${5:-0}"
  local outfile="${outfile_base%.zst}_${DATE_TS}.o3"

  wait_for_slot
  run_ssh_backup "${label}" "${host}" "${src_path}" "${outfile}" "${exclude_old}" "dir"
}

submit_files_backup() {
  local label="$1"
  local host="$2"
  local src_path="$3"
  local outfile_base="$4"
  local opdump_mode="${5:-REGULAR}"
  local outfile="${outfile_base%.zst}_${DATE_TS}.o3"

  wait_for_slot
  run_ssh_backup "${label}" "${host}" "${src_path}" "${outfile}" 0 "files_in_dir_${opdump_mode}"
}

# ==============================================================================
# START
# ==============================================================================
log_info "============================================================"
log_info "Backup started"
log_info "OPNO        : ${OPNO}"
log_info "JobID       : ${JobID}"
log_info "Schedule    : ${RUN_NAME}"
log_info "Dest dir    : ${DESTDIR}"
log_info "Log file    : ${LOGFILE}"
log_info "Parallel    : ${PARALLEL_JOBS}"
log_info "OPdump src  : ${CHOST}:${OPDUMP_SRC}"
log_info "OPdump mode : ${OPDUMP_MODE}"
log_info "GPG recipient: ${GPG_RECIPIENT}"
log_info "GPG sign enabled: ${GPG_SIGN_ENABLED}"
log_info "GPG signer      : ${GPG_SIGNER:-default secret key}"
log_info "GPG sign armor  : ${GPG_SIGN_ARMOR}"
log_info "GPG suffix      : ${GPG_FINAL_SUFFIX}"
log_info "ZSTD args   : ${ZSTD_ARGS}"
log_info "============================================================"

# ==============================================================================
# OP RUNNABLE CHECK
# ==============================================================================
for check in CHECK_CROSS_RUN_CODE CHECK_REP; do
  log_info "Performing $SrvName $DbName cb $OPNO $check"
  if ! "$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" "$check"; then
    log_err "$check failed"
    send_result_mail "ERROR - ${check} failed"
    exit 1
  fi
done

log_info "Performing $SrvName $DbName cb $OPNO BEGIN_OPERATION"
"$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" BEGIN_OPERATION 2>/dev/null || true

# ==============================================================================
# OPDUMP CHECK BEFORE SUBMIT BACKUP
# ==============================================================================
check_opdump_files "OPDUMP_${JobID}" "taifex-bk" "${OPDUMP_SRC}" "${OPDUMP_MODE}"
if [[ "$?" -ne 0 ]]; then
  log_err "OPdump source verification failed, stop backup."
  "$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" END_OPERATION_FAILED 2>/dev/null || true
  send_result_mail "ERROR - OPdump source verification failed"
  exit 2
fi

# ==============================================================================
# SUBMIT BACKUP JOBS
# ==============================================================================
if [[ "$JobID" == "Z0300" ]]; then
  submit_dir_backup   "APDATA_vix"                 "pfwk01"     "/vix/vixc"                 "${DESTDIR}/APDATA_vix_vixc.zst"                1
  submit_dir_backup   "APDATA_info_TradeDB_fut"    "pfwk01"     "/info/TradeDB/fut/old"     "${DESTDIR}/APDATA_info_TradeDB_fut_old.zst"    0
  submit_dir_backup   "APDATA_info_TradeDB_opt"    "pfwk01"     "/info/TradeDB/opt/old"     "${DESTDIR}/APDATA_info_TradeDB_opt_old.zst"    0
  submit_dir_backup   "APDATA_info_AM_fut"         "pfwk01"     "/info/AM/fut/old"          "${DESTDIR}/APDATA_info_AM_fut_old.zst"         0
  submit_dir_backup   "APDATA_info_AM_opt"         "pfwk01"     "/info/AM/opt/old"          "${DESTDIR}/APDATA_info_AM_opt_old.zst"         0

  submit_files_backup "APDATA_OPDUMP_data_old"     "taifex-bk"  "${OPDUMP_SRC}"             "${REMOTE_DEST}/APDATA_OPDUMP_data_old.zst"    "REGULAR"
fi

if [[ "$JobID" == "Z0300AH" ]]; then
  submit_dir_backup   "APDATA_AH_vixah"             "pfwka1"     "/vixah/vixc"                 "${DESTDIR}/APDATA_AH_vixah_vixc.zst"             1
  submit_dir_backup   "APDATA_AH_info_TradeDB_fut"  "pfwka1"     "/infoah/TradeDB/fut/old"     "${DESTDIR}/APDATA_AH_infoah_TradeDB_fut_old.zst" 0
  submit_dir_backup   "APDATA_AH_info_TradeDB_opt"  "pfwka1"     "/infoah/TradeDB/opt/old"     "${DESTDIR}/APDATA_AH_infoah_TradeDB_opt_old.zst" 0
  submit_dir_backup   "APDATA_AH_info_AM_fut"       "pfwka1"     "/infoah/AM/fut/old"          "${DESTDIR}/APDATA_AH_infoah_AM_fut_old.zst"      0
  submit_dir_backup   "APDATA_AH_info_AM_opt"       "pfwka1"     "/infoah/AM/opt/old"          "${DESTDIR}/APDATA_AH_infoah_AM_opt_old.zst"      0

  submit_files_backup "APDATA_AH_OPDUMP_data_oldah" "taifex-bk"  "${OPDUMP_SRC}"                "${REMOTE_DEST}/APDATA_AH_OPDUMP_data_oldah.zst" "AH"
fi

# ==============================================================================
# WAIT FOR ALL JOBS
# ==============================================================================
log_info "All jobs submitted, waiting for completion"
wait_all_jobs
log_info "All jobs finished"
log_info "Summary: total=${TOTAL_JOBS}, ok=${OK_JOBS}, fail=${FAIL_JOBS}"

# ==============================================================================
# LATEST SYMLINK
# ==============================================================================
mkdir -p "${BKROOT}/${RUN_NAME}"
chown -R changer:op "${BKROOT}/${RUN_NAME}"
chmod -R 775 "${BKROOT}/${RUN_NAME}"
ln -sfn "${DESTDIR}" "${BKROOT}/${RUN_NAME}/latest"
log_info "Updated symlink ${BKROOT}/${RUN_NAME}/latest -> ${DESTDIR}"

# ==============================================================================
# RSYNC LOCAL BACKUP FILES TO taifex-bk:/alldata
# ==============================================================================
DataArea=$(/usr/bin/readlink -f "${BKROOT}/${RUN_NAME}/latest")

log_info "Moving / Rsync data from [$DataArea] to $CHOST [$REMOTE_DEST], please wait ..."

ssh "${REMOTE_USER}@${CHOST}" "
  find '$DataArea/' -maxdepth 1 -type f -printf '%P\0' 2>/dev/null |
  rsync -avc --itemize-changes --partial --remove-source-files --files-from=- --from0 --out-format='%n' '$DataArea/' '$REMOTE_DEST/'
" | tee -a "$LOGFILE" 2>&1

RSYNC_RC=${PIPESTATUS[0]}

if [[ "$RSYNC_RC" -ne 0 ]]; then
  FAILED=1
  log_err "Rsync step failed, rc=${RSYNC_RC}"
else
  log_ok "Rsync step completed"
fi

log_info "ls -al --time-style=long-iso $REMOTE_DEST/"
ssh "${REMOTE_USER}@${CHOST}" "ls -al --time-style=long-iso '$REMOTE_DEST/'" | tee -a "$LOGFILE" 2>&1

log_info "Archival/move step finished."

# ==============================================================================
# END OPERATION
# ==============================================================================
if [[ "${FAILED}" -eq 0 ]]; then
  log_info "Performing $SrvName $DbName cb $OPNO END_OPERATION_SUCCESS"
  "$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" END_OPERATION_SUCCESS || log_err "END_OPERATION_SUCCESS hook failed"
else
  log_err "Performing $SrvName $DbName cb $OPNO END_OPERATION_FAILED"
  "$OPF_UTIL" "$SrvName" "$DbName" cb "$OPNO" END_OPERATION_FAILED 2>/dev/null || true
fi

# ==============================================================================
# RESULT
# ==============================================================================
if [[ "${FAILED}" -eq 0 ]]; then
  log_ok "Backup completed successfully"
  send_result_mail "OK"
  exit 0
else
  log_err "Backup completed with errors"
  send_result_mail "ERRORS"
  exit 2
fi

