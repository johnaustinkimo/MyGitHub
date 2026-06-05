#!/bin/bash
# ==============================================================================
# dell_disk_html_report_v3.sh
# Multi-server Dell iDRAC disk health HTML report wrapper
#
# Reads one or more servers.ini files in this format:
#   name|idrac_host_or_ip|username|password
#
# Calls check_dell_disk_health_v1.sh for each server, parses CSV output,
# and generates a pretty HTML report with host summary and drive-level details.
# ==============================================================================

set -o pipefail

VERSION="v3"
CHECK_SCRIPT="./check_dell_disk_health_v1.sh"
OUT_HTML="dell_disk_health_report_$(date '+%Y%m%d_%H%M%S').html"
WARN_THRESHOLD=70
CRIT_THRESHOLD=90
TIMEOUT=30
PARALLEL=1
SHOW_RAW=false
TMP_KEEP=false
TITLE="Dell iDRAC Disk Drive Health Report"

INI_FILES=()

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") -f servers.ini [-f more_servers.ini] [options]

Required:
  -f FILE     Server inventory file. May be specified multiple times.
              Format: name|idrac_host_or_ip|username|password

Options:
  -s FILE     Path to check_dell_disk_health_v1.sh (default: ${CHECK_SCRIPT})
  -o FILE     Output HTML file (default: ${OUT_HTML})
  -w NUM      SSD wear WARN threshold percent (default: ${WARN_THRESHOLD})
  -c NUM      SSD wear CRIT threshold percent (default: ${CRIT_THRESHOLD})
  -t NUM      HTTP timeout seconds per iDRAC request (default: ${TIMEOUT})
  -P NUM      Parallel host checks (default: ${PARALLEL})
  -r          Include raw checker output in collapsed HTML sections
  -k          Keep temporary working directory for troubleshooting
  -T TITLE    HTML report title
  -h          Show help

Example:
  chmod +x check_dell_disk_health_v1.sh dell_disk_html_report_v3.sh
  ./dell_disk_html_report_v3.sh -f dell_servers.ini -s ./check_dell_disk_health_v1.sh -o dell_report.html -P 5 -r

Cron example:
  30 8 * * * /opt/ssd/dell_disk_html_report_v3.sh -f /opt/ssd/dell_servers.ini -s /opt/ssd/check_dell_disk_health_v1.sh -o /var/www/html/dell_disk_report.html -P 5 >/tmp/dell_report.log 2>&1
USAGE
}

while getopts "f:s:o:w:c:t:P:rkT:h" opt; do
  case "$opt" in
    f) INI_FILES+=("$OPTARG") ;;
    s) CHECK_SCRIPT="$OPTARG" ;;
    o) OUT_HTML="$OPTARG" ;;
    w) WARN_THRESHOLD="$OPTARG" ;;
    c) CRIT_THRESHOLD="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    P) PARALLEL="$OPTARG" ;;
    r) SHOW_RAW=true ;;
    k) TMP_KEEP=true ;;
    T) TITLE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ ${#INI_FILES[@]} -eq 0 ]]; then
  echo "[ERROR] At least one -f servers.ini is required." >&2
  usage
  exit 1
fi

if [[ ! -x "$CHECK_SCRIPT" ]]; then
  echo "[ERROR] Checker script not executable: $CHECK_SCRIPT" >&2
  echo "        Run: chmod +x $CHECK_SCRIPT" >&2
  exit 1
fi

# Normalize checker path.
# Important: if user passes -s check_dell_disk_health_v1.sh, Bash will search PATH
# when executing it. Current directory is usually not in PATH, so that becomes
# exit code 127. Convert readable relative file paths to ./file or absolute path.
if [[ "$CHECK_SCRIPT" != */* ]]; then
  CHECK_SCRIPT="./$CHECK_SCRIPT"
fi

for cmd in awk sed grep date mktemp sort; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Missing command: $cmd" >&2
    exit 1
  fi
done

if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [[ "$PARALLEL" -lt 1 ]]; then
  echo "[ERROR] -P must be a positive integer." >&2
  exit 1
fi

TMPDIR=$(mktemp -d /tmp/dell_disk_report.XXXXXX)
trap '[[ "$TMP_KEEP" == true ]] || rm -rf "$TMPDIR"' EXIT

HOST_LIST="$TMPDIR/hosts.tsv"
: > "$HOST_LIST"

line_no=0
for ini in "${INI_FILES[@]}"; do
  if [[ ! -r "$ini" ]]; then
    echo "[ERROR] Cannot read inventory file: $ini" >&2
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    # Trim CR for Windows-edited files.
    line=${line%$'\r'}
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    IFS='|' read -r name host user pass extra <<< "$line"
    if [[ -z "$name" || -z "$host" || -z "$user" || -z "$pass" ]]; then
      echo "[WARN] Skip invalid line in $ini:$line_no : $line" >&2
      continue
    fi
    if [[ -n "$extra" ]]; then
      echo "[WARN] Extra field ignored in $ini:$line_no : $line" >&2
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$host" "$user" "$pass" "$ini" >> "$HOST_LIST"
  done < "$ini"
done

TOTAL_HOSTS=$(wc -l < "$HOST_LIST" | tr -d ' ')
if [[ "$TOTAL_HOSTS" -eq 0 ]]; then
  echo "[ERROR] No valid hosts found in inventory files." >&2
  exit 1
fi

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

csv_escape_to_tsv() {
  # The checker emits simple comma-separated rows without quoted commas.
  # Convert exactly the expected 11 columns into tab-separated values.
  awk -F',' 'NF>=11 {
    ctrl=$1; loc=$2; model=$3; serial=$4; media=$5; health=$6; state=$7; ssd=$8; cap=$9; fw=$10; fail=$11;
    print ctrl "\t" loc "\t" model "\t" serial "\t" media "\t" health "\t" state "\t" ssd "\t" cap "\t" fw "\t" fail
  }'
}

run_one_host() {
  local idx="$1" name="$2" host="$3" user="$4" pass="$5" src_ini="$6"
  local out="$TMPDIR/host_${idx}.out"
  local csv="$TMPDIR/host_${idx}.drives.tsv"
  local meta="$TMPDIR/host_${idx}.meta"
  local start_epoch end_epoch duration exit_code status class total unhealthy ssd_alerts no_drives

  # Pre-create files so later report generation never fails with missing host_N files.
  : > "$out" || { echo "[ERROR] Cannot create temp output: $out" >&2; return 1; }
  : > "$csv" || { echo "[ERROR] Cannot create temp CSV: $csv" >&2; return 1; }
  : > "$meta" || { echo "[ERROR] Cannot create temp metadata: $meta" >&2; return 1; }

  start_epoch=$(date +%s)

  "$CHECK_SCRIPT" -H "$host" -u "$user" -p "$pass" \
    -o csv -w "$WARN_THRESHOLD" -c "$CRIT_THRESHOLD" -t "$TIMEOUT" > "$out" 2>&1
  exit_code=$?

  end_epoch=$(date +%s)
  duration=$((end_epoch - start_epoch))

  # Extract only the CSV block produced by render_csv().
  # Stop at status lines or the summary separator. This prevents table/debug text
  # from leaking into the CSV parser.
  awk '
    /^Controller,Location,Model,SerialNumber,MediaType,Health,State,SSDEnduranceUsed%,CapacityGB,FirmwareVersion,FailurePredicted$/ { in_csv=1; next }
    in_csv && /^\[/ { in_csv=0 }
    in_csv && /^═/ { in_csv=0 }
    in_csv && NF { print }
  ' "$out" | csv_escape_to_tsv > "$csv"

  total=$(wc -l < "$csv" | tr -d ' ')
  unhealthy=$(awk -F'\t' '($6 != "OK" && $6 != "N/A" && $6 != "") || $11 == "true" {c++} END{print c+0}' "$csv")
  ssd_alerts=$(awk -F'\t' -v warn="$WARN_THRESHOLD" '($8 != "N/A" && $8 != "" && $8+0 >= warn) {c++} END{print c+0}' "$csv")

  no_drives=0
  [[ "$total" -eq 0 ]] && no_drives=1

  case "$exit_code" in
    0) status="OK"; class="ok" ;;
    2) status="ACTION REQUIRED"; class="crit" ;;
    3) status="NO DRIVES"; class="warn" ;;
    4) status="CONNECTION ERROR"; class="crit" ;;
    *) status="ERROR ${exit_code}"; class="crit" ;;
  esac

  # If the checker actually ran, parser-derived findings can refine status.
  # Do not hide command/runtime errors such as 127 behind "NO DRIVES".
  if [[ "$unhealthy" -gt 0 || "$ssd_alerts" -gt 0 ]]; then
    status="ACTION REQUIRED"
    class="crit"
  elif [[ "$no_drives" -eq 1 && "$exit_code" -eq 0 ]]; then
    status="NO DRIVES"
    class="warn"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$idx" "$name" "$host" "$src_ini" "$status" "$class" "$total" "$unhealthy" "$ssd_alerts" "$duration" "$exit_code" > "$meta"
}

idx=0
pids=()

# Run checks with a portable PID queue instead of wait -n.
# Some RHEL/CentOS bash versions either do not support wait -n or return non-zero
# when a child exits with a warning/error code. That could make the old wrapper
# continue while temp files were not ready, causing host_N.out / host_N.meta errors.
while IFS=$'\t' read -r name host user pass src_ini; do
  idx=$((idx + 1))
  echo "[INFO] Checking ${idx}/${TOTAL_HOSTS}: ${name} (${host})"

  if [[ "$PARALLEL" -eq 1 ]]; then
    run_one_host "$idx" "$name" "$host" "$user" "$pass" "$src_ini"
  else
    run_one_host "$idx" "$name" "$host" "$user" "$pass" "$src_ini" &
    pids+=("$!")

    if [[ "${#pids[@]}" -ge "$PARALLEL" ]]; then
      wait "${pids[0]}" || true
      pids=("${pids[@]:1}")
    fi
  fi
done < "$HOST_LIST"

for pid in "${pids[@]}"; do
  wait "$pid" || true
done
SUMMARY_TSV="$TMPDIR/summary.tsv"
: > "$SUMMARY_TSV"
for meta in "$TMPDIR"/host_*.meta; do
  [[ -f "$meta" ]] && cat "$meta" >> "$SUMMARY_TSV"
done
sort -n -k1,1 "$SUMMARY_TSV" -o "$SUMMARY_TSV"

OK_HOSTS=$(awk -F'\t' '$6=="ok" {c++} END{print c+0}' "$SUMMARY_TSV")
WARN_HOSTS=$(awk -F'\t' '$6=="warn" {c++} END{print c+0}' "$SUMMARY_TSV")
CRIT_HOSTS=$(awk -F'\t' '$6=="crit" {c++} END{print c+0}' "$SUMMARY_TSV")
TOTAL_DRIVES=$(awk -F'\t' '{sum+=$7} END{print sum+0}' "$SUMMARY_TSV")
TOTAL_UNHEALTHY=$(awk -F'\t' '{sum+=$8} END{print sum+0}' "$SUMMARY_TSV")
TOTAL_SSD_ALERTS=$(awk -F'\t' '{sum+=$9} END{print sum+0}' "$SUMMARY_TSV")
GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S %Z')

OUT_DIR=$(dirname "$OUT_HTML")
if [[ "$OUT_DIR" != "." && ! -d "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR" || {
    echo "[ERROR] Cannot create output directory: $OUT_DIR" >&2
    exit 1
  }
fi

{
cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(printf '%s' "$TITLE" | html_escape)</title>
<style>
:root {
  --bg: #f5f7fb;
  --card: #ffffff;
  --text: #172033;
  --muted: #65758b;
  --border: #d8e0ea;
  --ok: #15803d;
  --ok-bg: #dcfce7;
  --warn: #b45309;
  --warn-bg: #fef3c7;
  --crit: #b91c1c;
  --crit-bg: #fee2e2;
  --info-bg: #e0f2fe;
  --shadow: 0 6px 20px rgba(15, 23, 42, .08);
}
* { box-sizing: border-box; }
body { margin: 0; padding: 28px; background: var(--bg); color: var(--text); font-family: Arial, Helvetica, sans-serif; }
h1 { margin: 0 0 6px 0; font-size: 28px; }
.subtitle { color: var(--muted); margin-bottom: 22px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 16px; box-shadow: var(--shadow); margin-bottom: 22px; overflow: hidden; }
.card-header { padding: 16px 18px; border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center; gap: 12px; }
.card-body { padding: 18px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 14px; }
.metric { border: 1px solid var(--border); border-radius: 14px; padding: 14px; background: #fbfdff; }
.metric .label { color: var(--muted); font-size: 13px; }
.metric .value { font-size: 28px; font-weight: 700; margin-top: 6px; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: 10px 11px; border-bottom: 1px solid var(--border); text-align: left; vertical-align: top; font-size: 14px; }
th { background: #f8fafc; color: #334155; position: sticky; top: 0; z-index: 1; }
tr:hover td { background: #f8fafc; }
.badge { display: inline-block; padding: 4px 9px; border-radius: 999px; font-weight: 700; font-size: 12px; white-space: nowrap; }
.badge.ok { color: var(--ok); background: var(--ok-bg); }
.badge.warn { color: var(--warn); background: var(--warn-bg); }
.badge.crit { color: var(--crit); background: var(--crit-bg); }
.host-title { font-size: 18px; font-weight: 700; }
.host-meta { color: var(--muted); font-size: 13px; }
.small { color: var(--muted); font-size: 12px; }
.scroll { overflow-x: auto; }
details { margin-top: 12px; }
summary { cursor: pointer; color: #1d4ed8; font-weight: 700; }
pre { white-space: pre-wrap; background: #0f172a; color: #e5e7eb; padding: 14px; border-radius: 12px; overflow-x: auto; font-size: 12px; }
.footer { color: var(--muted); font-size: 12px; text-align: center; margin-top: 30px; }
@media print {
  body { padding: 12px; background: #fff; }
  .card { box-shadow: none; break-inside: avoid; }
  th { position: static; }
}
</style>
</head>
<body>
<h1>$(printf '%s' "$TITLE" | html_escape)</h1>
<div class="subtitle">Generated at ${GENERATED_AT}. SSD thresholds: warn &ge; ${WARN_THRESHOLD}%, critical &ge; ${CRIT_THRESHOLD}%.</div>

<div class="card">
  <div class="card-header"><div class="host-title">Overall Summary</div><div class="small">Inventory files: $(printf '%s' "${INI_FILES[*]}" | html_escape)</div></div>
  <div class="card-body">
    <div class="grid">
      <div class="metric"><div class="label">Hosts checked</div><div class="value">${TOTAL_HOSTS}</div></div>
      <div class="metric"><div class="label">OK hosts</div><div class="value">${OK_HOSTS}</div></div>
      <div class="metric"><div class="label">Warning hosts</div><div class="value">${WARN_HOSTS}</div></div>
      <div class="metric"><div class="label">Critical/error hosts</div><div class="value">${CRIT_HOSTS}</div></div>
      <div class="metric"><div class="label">Total drives</div><div class="value">${TOTAL_DRIVES}</div></div>
      <div class="metric"><div class="label">Unhealthy / failed drives</div><div class="value">${TOTAL_UNHEALTHY}</div></div>
      <div class="metric"><div class="label">SSD wear alerts</div><div class="value">${TOTAL_SSD_ALERTS}</div></div>
    </div>
  </div>
</div>

<div class="card">
  <div class="card-header"><div class="host-title">Host Summary</div></div>
  <div class="card-body scroll">
    <table>
      <thead><tr><th>#</th><th>Host name</th><th>iDRAC IP / Host</th><th>Status</th><th>Total drives</th><th>Unhealthy / failed</th><th>SSD alerts</th><th>Duration</th><th>Exit</th></tr></thead>
      <tbody>
HTML

while IFS=$'\t' read -r idx name host src_ini status class total unhealthy ssd_alerts duration exit_code; do
  esc_name=$(printf '%s' "$name" | html_escape)
  esc_host=$(printf '%s' "$host" | html_escape)
  esc_status=$(printf '%s' "$status" | html_escape)
  printf '        <tr><td>%s</td><td><strong>%s</strong><div class="small">%s</div></td><td>%s</td><td><span class="badge %s">%s</span></td><td>%s</td><td>%s</td><td>%s</td><td>%ss</td><td>%s</td></tr>\n' \
    "$idx" "$esc_name" "$(printf '%s' "$src_ini" | html_escape)" "$esc_host" "$class" "$esc_status" "$total" "$unhealthy" "$ssd_alerts" "$duration" "$exit_code"
done < "$SUMMARY_TSV"

cat <<HTML
      </tbody>
    </table>
  </div>
</div>
HTML

while IFS=$'\t' read -r idx name host src_ini status class total unhealthy ssd_alerts duration exit_code; do
  drives="$TMPDIR/host_${idx}.drives.tsv"
  raw="$TMPDIR/host_${idx}.out"
  esc_name=$(printf '%s' "$name" | html_escape)
  esc_host=$(printf '%s' "$host" | html_escape)
  esc_status=$(printf '%s' "$status" | html_escape)

  cat <<HTML
<div class="card">
  <div class="card-header">
    <div>
      <div class="host-title">${idx}. ${esc_name}</div>
      <div class="host-meta">iDRAC: ${esc_host} | Source: $(printf '%s' "$src_ini" | html_escape) | Duration: ${duration}s</div>
    </div>
    <span class="badge ${class}">${esc_status}</span>
  </div>
  <div class="card-body scroll">
HTML

  if [[ -s "$drives" ]]; then
    cat <<HTML
    <table>
      <thead><tr><th>Controller</th><th>Bay</th><th>Model</th><th>Serial</th><th>Type</th><th>Health</th><th>State</th><th>SSD wear</th><th>Capacity GB</th><th>FW</th><th>Failure predicted</th></tr></thead>
      <tbody>
HTML
    while IFS=$'\t' read -r ctrl loc model serial media health state ssd cap fw fail; do
      hclass="ok"
      [[ "$health" != "OK" && "$health" != "N/A" && -n "$health" ]] && hclass="crit"
      [[ "$fail" == "true" ]] && hclass="crit"
      sclass="ok"
      if [[ "$ssd" != "N/A" && -n "$ssd" ]]; then
        awk -v s="$ssd" -v c="$CRIT_THRESHOLD" 'BEGIN{exit !(s+0>=c)}' && sclass="crit"
        if [[ "$sclass" != "crit" ]]; then
          awk -v s="$ssd" -v w="$WARN_THRESHOLD" 'BEGIN{exit !(s+0>=w)}' && sclass="warn"
        fi
      fi
      if [[ "$ssd" == "N/A" || -z "$ssd" ]]; then
        ssd_display="N/A"
      else
        ssd_display="${ssd}%"
      fi
      printf '        <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td><span class="badge %s">%s</span></td><td>%s</td><td><span class="badge %s">%s</span></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
        "$(printf '%s' "$ctrl" | html_escape)" \
        "$(printf '%s' "$loc" | html_escape)" \
        "$(printf '%s' "$model" | html_escape)" \
        "$(printf '%s' "$serial" | html_escape)" \
        "$(printf '%s' "$media" | html_escape)" \
        "$hclass" "$(printf '%s' "$health" | html_escape)" \
        "$(printf '%s' "$state" | html_escape)" \
        "$sclass" "$(printf '%s' "$ssd_display" | html_escape)" \
        "$(printf '%s' "$cap" | html_escape)" \
        "$(printf '%s' "$fw" | html_escape)" \
        "$(printf '%s' "$fail" | html_escape)"
    done < "$drives"
    cat <<HTML
      </tbody>
    </table>
HTML
  else
    cat <<HTML
    <p><span class="badge ${class}">${esc_status}</span> No drive rows were parsed. Check connectivity, credentials, iDRAC Redfish support, or raw output.</p>
HTML
  fi

  if [[ "$SHOW_RAW" == true ]]; then
    cat <<HTML
    <details>
      <summary>Raw checker output</summary>
      <pre>$(cat "$raw" | html_escape)</pre>
    </details>
HTML
  fi

  cat <<HTML
  </div>
</div>
HTML
done < "$SUMMARY_TSV"

cat <<HTML
<div class="footer">Generated by dell_disk_html_report_v3.sh ${VERSION}. Passwords are read from inventory files but are not written to this report.</div>
</body>
</html>
HTML
} > "$OUT_HTML"

if [[ "$CRIT_HOSTS" -gt 0 || "$TOTAL_UNHEALTHY" -gt 0 || "$TOTAL_SSD_ALERTS" -gt 0 ]]; then
  final_rc=2
elif [[ "$WARN_HOSTS" -gt 0 ]]; then
  final_rc=1
else
  final_rc=0
fi

echo "[OK] HTML report created: $OUT_HTML"
echo "[INFO] Hosts=${TOTAL_HOSTS}, OK=${OK_HOSTS}, WARN=${WARN_HOSTS}, CRIT=${CRIT_HOSTS}, Drives=${TOTAL_DRIVES}, Unhealthy=${TOTAL_UNHEALTHY}, SSDAlerts=${TOTAL_SSD_ALERTS}"
[[ "$TMP_KEEP" == true ]] && echo "[INFO] Temporary files kept at: $TMPDIR"
#exit "$final_rc"

recipients=(
    sys-linux@taifex.com.tw
    sys-op@taifex.com.tw
    sysalert@taifex.com.tw
)
 TO="${recipients[@]}"
#TO="jeffreyhu@taifex.com.tw"
XTAG="[OADMZ] ProLiant DL380 Gen8/9/10 Redfish SSD Endurance Healthy Report"
#/usr/local/bin/weasyprint "$OUT_HTML" "$OUT_PDF"
#echo "✅ PDF generated: $OUT_PDF"
#echo "請查收 ${XTAG}（PDF 附件）" | mailx -a "$OUT_PDF" -a "$OUT_HTML" -s "${XTAG}（Hosts=${TOTAL_HOSTS}, OK=${OK_HOSTS}, WARN=${WARN_HOSTS}, CRIT=${CRIT_HOSTS}, Drives=${TOTAL_DRIVES}, Unhealthy=${TOTAL_UNHEALTHY}, SSDAlerts=${TOTAL_SSD_ALERTS}）" $TO
echo "${XTAG}" | mailx -a "$OUT_HTML" -s "${XTAG} ( Hosts=${TOTAL_HOSTS}, OK=${OK_HOSTS}, WARN=${WARN_HOSTS}, CRIT=${CRIT_HOSTS}, Drives=${TOTAL_DRIVES}, Unhealthy=${TOTAL_UNHEALTHY}, SSDAlerts=${TOTAL_SSD_ALERTS} )" $TO

exit "$final_rc"
