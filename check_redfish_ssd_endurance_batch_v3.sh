#!/bin/bash
#
# check_redfish_ssd_endurance_batch_v3.sh
#
# Purpose:
#   Query multiple HPE iLO Redfish servers from servers.ini
#   Check all SSD SSDEnduranceUtilizationPercentage
#   Generate pretty HTML summary/detail report and CSV detail report.
#
# servers.ini format:
#   name|ilo_ip|user|password
#
# Example:
#   AP-Server-01|192.168.29.13|cose|Taifex123456
#
# Exit code:
#   0 = OK
#   1 = WARNING
#   2 = CRITICAL
#   3 = UNKNOWN
#

set -o pipefail

SERVER_FILE="servers.ini"
WARN=70
CRIT=85
CURL_TIMEOUT=20
OUTDIR="./report"
REPORT_DATE="$(date '+%Y%m%d_%H%M%S')"
HTML_REPORT=""
CSV_REPORT=""
INSECURE="-k"

TOTAL_SERVERS=0
OK_SERVERS=0
WARN_SERVERS=0
CRIT_SERVERS=0
UNKNOWN_SERVERS=0

TOTAL_DISKS=0
OK_DISKS=0
WARN_DISKS=0
CRIT_DISKS=0
UNKNOWN_DISKS=0

GLOBAL_STATUS=0

TMP_DETAIL="$(mktemp)"
TMP_SUMMARY="$(mktemp)"

usage() {
  cat <<EOF
Usage:
  $0 -f <servers.ini> [-w warn_percent] [-c crit_percent] [-o output_dir] [-t timeout]

Example:
  $0 -f servers.ini -w 70 -c 85 -o ./report

servers.ini format:
  name|ilo_ip|user|password

Example:
  AP-Server-01|192.168.29.13|cose|Taifex123456
  DB-Server-01|192.168.29.14|Administrator|YourPassword

Meaning:
  SSDEnduranceUtilizationPercentage = SSD endurance used percentage.
  Higher value means more SSD wear.
EOF
}

html_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&#39;/g"
}

redfish_get() {
  local ilo_host="$1"
  local ilo_user="$2"
  local ilo_pass="$3"
  local uri="$4"

  curl ${INSECURE} -sS \
    --connect-timeout "${CURL_TIMEOUT}" \
    --max-time "${CURL_TIMEOUT}" \
    -u "${ilo_user}:${ilo_pass}" \
    -H "Accept: application/json" \
    "https://${ilo_host}${uri}" 2>/dev/null
}

status_class() {
  local status="$1"

  case "$status" in
    OK) echo "status-ok" ;;
    WARNING) echo "status-warning" ;;
    CRITICAL) echo "status-critical" ;;
    UNKNOWN) echo "status-unknown" ;;
    *) echo "status-unknown" ;;
  esac
}

set_global_status() {
  local code="$1"

  if (( code > GLOBAL_STATUS )); then
    GLOBAL_STATUS="$code"
  fi
}

get_drive_uris_for_server() {
  local ilo_host="$1"
  local ilo_user="$2"
  local ilo_pass="$3"

  local systems_json
  local system_uris
  local drive_uris=""
  local system_uri

  systems_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "/redfish/v1/Systems")"

  if ! echo "$systems_json" | jq empty >/dev/null 2>&1; then
    return 1
  fi

  system_uris="$(echo "$systems_json" | jq -r '.Members[]?."@odata.id"')"

  if [[ -z "$system_uris" ]]; then
    return 2
  fi

  # Preferred HPE SmartStorage path
  for system_uri in $system_uris; do
    local array_controllers_uri
    local array_controllers_json
    local controller_uris
    local controller_uri

    array_controllers_uri="${system_uri%/}/SmartStorage/ArrayControllers"
    array_controllers_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$array_controllers_uri")"

    if ! echo "$array_controllers_json" | jq empty >/dev/null 2>&1; then
      continue
    fi

    controller_uris="$(echo "$array_controllers_json" | jq -r '.Members[]?."@odata.id"')"

    for controller_uri in $controller_uris; do
      local controller_json
      local pd_collection_uri
      local pd_collection_json
      local found_drives

      controller_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$controller_uri")"

      if ! echo "$controller_json" | jq empty >/dev/null 2>&1; then
        continue
      fi

      pd_collection_uri="$(echo "$controller_json" | jq -r '
        .Links.PhysicalDrives."@odata.id" //
        .links.PhysicalDrives."@odata.id" //
        empty
      ')"

      if [[ -z "$pd_collection_uri" ]]; then
        continue
      fi

      pd_collection_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$pd_collection_uri")"

      if ! echo "$pd_collection_json" | jq empty >/dev/null 2>&1; then
        continue
      fi

      found_drives="$(echo "$pd_collection_json" | jq -r '.Members[]?."@odata.id"')"

      if [[ -n "$found_drives" ]]; then
        drive_uris="${drive_uris}
${found_drives}"
      fi
    done
  done

  # Fallback standard Redfish Storage path only if SmartStorage found nothing
  if [[ -z "$(echo "$drive_uris" | sed '/^[[:space:]]*$/d')" ]]; then
    for system_uri in $system_uris; do
      local storage_uri
      local storage_json
      local storage_members
      local storage_member_uri

      storage_uri="${system_uri%/}/Storage"
      storage_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$storage_uri")"

      if ! echo "$storage_json" | jq empty >/dev/null 2>&1; then
        continue
      fi

      storage_members="$(echo "$storage_json" | jq -r '.Members[]?."@odata.id"')"

      for storage_member_uri in $storage_members; do
        local storage_member_json
        local found_drives

        storage_member_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$storage_member_uri")"

        if ! echo "$storage_member_json" | jq empty >/dev/null 2>&1; then
          continue
        fi

        found_drives="$(echo "$storage_member_json" | jq -r '.Drives[]?."@odata.id"')"

        if [[ -n "$found_drives" ]]; then
          drive_uris="${drive_uris}
${found_drives}"
        fi
      done
    done
  fi

  echo "$drive_uris" | sed '/^[[:space:]]*$/d' | sort -u
  return 0
}

check_one_server() {
  local server_name="$1"
  local ilo_host="$2"
  local ilo_user="$3"
  local ilo_pass="$4"

  local server_status="OK"
  local server_code=0
  local server_total=0
  local server_ok=0
  local server_warn=0
  local server_crit=0
  local server_unknown=0
  local drive_uris
  local rc

  TOTAL_SERVERS=$((TOTAL_SERVERS + 1))

  drive_uris="$(get_drive_uris_for_server "$ilo_host" "$ilo_user" "$ilo_pass")"
  rc=$?

  if (( rc != 0 )) || [[ -z "$drive_uris" ]]; then
    server_status="UNKNOWN"
    server_code=3
    server_unknown=1
    UNKNOWN_SERVERS=$((UNKNOWN_SERVERS + 1))
    UNKNOWN_DISKS=$((UNKNOWN_DISKS + 1))
    set_global_status 3

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$ilo_host" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "No Redfish drive URI found or API failed" "-" "-" >> "$TMP_DETAIL"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$ilo_host" "$server_status" 0 0 0 0 1 "No drive data found" >> "$TMP_SUMMARY"

    return
  fi

  while read -r drive_uri; do
    [[ -z "$drive_uri" ]] && continue

    local drive_json
    local endurance
    local name
    local model
    local serial
    local media_type
    local health
    local state
    local capacity
    local drive_status
    local message

    drive_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$drive_uri")"

    server_total=$((server_total + 1))
    TOTAL_DISKS=$((TOTAL_DISKS + 1))

    if ! echo "$drive_json" | jq empty >/dev/null 2>&1; then
      drive_status="UNKNOWN"
      message="Invalid JSON or API error"
      endurance="UNKNOWN"
      name="UNKNOWN"
      model="UNKNOWN"
      serial="UNKNOWN"
      media_type="UNKNOWN"
      health="UNKNOWN"
      state="UNKNOWN"
      capacity="UNKNOWN"

      server_unknown=$((server_unknown + 1))
      UNKNOWN_DISKS=$((UNKNOWN_DISKS + 1))
      server_code=3
      set_global_status 3
    else
      endurance="$(echo "$drive_json" | jq -r '
        .SSDEnduranceUtilizationPercentage //
        (.. | objects | .SSDEnduranceUtilizationPercentage? // empty) |
        select(. != null) |
        tostring
      ' 2>/dev/null | head -n 1)"

      name="$(echo "$drive_json" | jq -r '.Name // .Id // "UnknownDrive"')"
      model="$(echo "$drive_json" | jq -r '.Model // "UnknownModel"')"
      serial="$(echo "$drive_json" | jq -r '.SerialNumber // .serialNumber // "UnknownSerial"')"
      media_type="$(echo "$drive_json" | jq -r '.MediaType // .mediaType // "UnknownMedia"')"
      health="$(echo "$drive_json" | jq -r '.Status.Health // "UnknownHealth"')"
      state="$(echo "$drive_json" | jq -r '.Status.State // "UnknownState"')"

      capacity="$(echo "$drive_json" | jq -r '
        .CapacityBytes //
        .capacityBytes //
        empty
      ' 2>/dev/null | head -n 1)"

      if [[ -n "$capacity" && "$capacity" != "null" && "$capacity" =~ ^[0-9]+$ ]]; then
        capacity="$(awk -v b="$capacity" 'BEGIN { printf "%.2f GB", b/1024/1024/1024 }')"
      else
        capacity="UNKNOWN"
      fi

      if [[ -z "$endurance" || "$endurance" == "null" ]]; then
        drive_status="UNKNOWN"
        message="No SSDEnduranceUtilizationPercentage found"
        endurance="UNKNOWN"

        server_unknown=$((server_unknown + 1))
        UNKNOWN_DISKS=$((UNKNOWN_DISKS + 1))

        if (( server_code < 3 )); then
          server_code=3
        fi
        set_global_status 3

      elif ! [[ "$endurance" =~ ^[0-9]+$ ]]; then
        drive_status="UNKNOWN"
        message="Invalid endurance value"
        server_unknown=$((server_unknown + 1))
        UNKNOWN_DISKS=$((UNKNOWN_DISKS + 1))

        if (( server_code < 3 )); then
          server_code=3
        fi
        set_global_status 3

      elif (( endurance >= CRIT )); then
        drive_status="CRITICAL"
        message="SSD endurance used >= critical threshold"
        server_crit=$((server_crit + 1))
        CRIT_DISKS=$((CRIT_DISKS + 1))
        server_code=2
        set_global_status 2

      elif (( endurance >= WARN )); then
        drive_status="WARNING"
        message="SSD endurance used >= warning threshold"
        server_warn=$((server_warn + 1))
        WARN_DISKS=$((WARN_DISKS + 1))

        if (( server_code < 1 )); then
          server_code=1
        fi
        set_global_status 1

      else
        drive_status="OK"
        message="SSD endurance used below warning threshold"
        server_ok=$((server_ok + 1))
        OK_DISKS=$((OK_DISKS + 1))
      fi
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$ilo_host" "$drive_status" "$name" "$serial" "$model" "$media_type" \
      "$capacity" "$endurance" "$health" "$state" "$message" "$drive_uri" "$(date '+%F %T')" >> "$TMP_DETAIL"

  done <<< "$drive_uris"

  if (( server_code == 2 )); then
    server_status="CRITICAL"
    CRIT_SERVERS=$((CRIT_SERVERS + 1))
  elif (( server_code == 1 )); then
    server_status="WARNING"
    WARN_SERVERS=$((WARN_SERVERS + 1))
  elif (( server_code == 3 )); then
    server_status="UNKNOWN"
    UNKNOWN_SERVERS=$((UNKNOWN_SERVERS + 1))
  else
    server_status="OK"
    OK_SERVERS=$((OK_SERVERS + 1))
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$server_name" "$ilo_host" "$server_status" "$server_total" "$server_ok" "$server_warn" "$server_crit" "$server_unknown" "Completed" >> "$TMP_SUMMARY"
}

generate_csv() {
  {
    echo "ServerName,iLOHost,Status,DriveName,Serial,Model,MediaType,Capacity,SSDEnduranceUsedPercent,Health,State,Message,DriveURI,CheckTime"
    while IFS='|' read -r server_name ilo_host status name serial model media_type capacity endurance health state message drive_uri check_time; do
      printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$server_name" "$ilo_host" "$status" "$name" "$serial" "$model" "$media_type" "$capacity" "$endurance" "$health" "$state" "$message" "$drive_uri" "$check_time"
    done < "$TMP_DETAIL"
  } > "$CSV_REPORT"
}

generate_html() {
  local generated_time
  generated_time="$(date '+%F %T')"

  cat > "$HTML_REPORT" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Redfish SSD Endurance Report</title>
<style>
body {
  font-family: Arial, Helvetica, sans-serif;
  background: #f4f6f8;
  color: #222;
  margin: 20px;
}

h1 {
  margin-bottom: 5px;
}

h2 {
  margin-top: 30px;
  border-left: 6px solid #2f6fed;
  padding-left: 10px;
}

.report-meta {
  color: #555;
  margin-bottom: 20px;
}

.summary-cards {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-bottom: 25px;
}

.card {
  background: #fff;
  border-radius: 8px;
  padding: 14px 18px;
  box-shadow: 0 1px 4px rgba(0,0,0,0.12);
  min-width: 140px;
}

.card-title {
  color: #666;
  font-size: 13px;
}

.card-value {
  font-size: 26px;
  font-weight: bold;
  margin-top: 5px;
}

table {
  border-collapse: collapse;
  width: 100%;
  background: #fff;
  margin-top: 10px;
  box-shadow: 0 1px 4px rgba(0,0,0,0.12);
}

th {
  background: #263238;
  color: #fff;
  padding: 8px;
  font-size: 13px;
  text-align: left;
  position: sticky;
  top: 0;
}

td {
  padding: 7px 8px;
  border-bottom: 1px solid #e0e0e0;
  font-size: 13px;
  vertical-align: top;
}

tr:hover {
  background: #f1f7ff;
}

.status-ok {
  background: #d9f7df;
  color: #126b25;
  font-weight: bold;
  text-align: center;
  border-radius: 4px;
  padding: 4px 8px;
  display: inline-block;
}

.status-warning {
  background: #fff4ce;
  color: #8a5a00;
  font-weight: bold;
  text-align: center;
  border-radius: 4px;
  padding: 4px 8px;
  display: inline-block;
}

.status-critical {
  background: #fde2e2;
  color: #b00020;
  font-weight: bold;
  text-align: center;
  border-radius: 4px;
  padding: 4px 8px;
  display: inline-block;
}

.status-unknown {
  background: #e5e7eb;
  color: #374151;
  font-weight: bold;
  text-align: center;
  border-radius: 4px;
  padding: 4px 8px;
  display: inline-block;
}

.small {
  font-size: 12px;
  color: #666;
}

.uri {
  font-family: Consolas, monospace;
  font-size: 12px;
  color: #444;
  word-break: break-all;
}

.footer {
  margin-top: 25px;
  color: #666;
  font-size: 12px;
}
</style>
</head>
<body>

<h1>Redfish SSD Endurance Report</h1>
<div class="report-meta">
Generated Time: ${generated_time}<br>
Warning Threshold: ${WARN}% &nbsp;&nbsp; Critical Threshold: ${CRIT}%
</div>

<div class="summary-cards">
  <div class="card">
    <div class="card-title">Total Servers</div>
    <div class="card-value">${TOTAL_SERVERS}</div>
  </div>
  <div class="card">
    <div class="card-title">OK Servers</div>
    <div class="card-value">${OK_SERVERS}</div>
  </div>
  <div class="card">
    <div class="card-title">Warning Servers</div>
    <div class="card-value">${WARN_SERVERS}</div>
  </div>
  <div class="card">
    <div class="card-title">Critical Servers</div>
    <div class="card-value">${CRIT_SERVERS}</div>
  </div>
  <div class="card">
    <div class="card-title">Unknown Servers</div>
    <div class="card-value">${UNKNOWN_SERVERS}</div>
  </div>
  <div class="card">
    <div class="card-title">Total Disks</div>
    <div class="card-value">${TOTAL_DISKS}</div>
  </div>
</div>

<h2>Server Summary</h2>
<table>
<thead>
<tr>
  <th>Server Name</th>
  <th>iLO Host</th>
  <th>Status</th>
  <th>Total Disk</th>
  <th>OK</th>
  <th>Warning</th>
  <th>Critical</th>
  <th>Unknown</th>
  <th>Message</th>
</tr>
</thead>
<tbody>
EOF

  while IFS='|' read -r server_name ilo_host status total ok warn crit unknown message; do
    local cls
    cls="$(status_class "$status")"

    cat >> "$HTML_REPORT" <<EOF
<tr>
  <td>$(echo "$server_name" | html_escape)</td>
  <td>$(echo "$ilo_host" | html_escape)</td>
  <td><span class="${cls}">$(echo "$status" | html_escape)</span></td>
  <td>${total}</td>
  <td>${ok}</td>
  <td>${warn}</td>
  <td>${crit}</td>
  <td>${unknown}</td>
  <td>$(echo "$message" | html_escape)</td>
</tr>
EOF
  done < "$TMP_SUMMARY"

  cat >> "$HTML_REPORT" <<EOF
</tbody>
</table>

<h2>SSD Drive Detail</h2>
<table>
<thead>
<tr>
  <th>Server Name</th>
  <th>iLO Host</th>
  <th>Status</th>
  <th>Drive Name</th>
  <th>Serial</th>
  <th>Model</th>
  <th>Media</th>
  <th>Capacity</th>
  <th>SSD Used %</th>
  <th>Health</th>
  <th>State</th>
  <th>Message</th>
  <th>Drive URI</th>
  <th>Check Time</th>
</tr>
</thead>
<tbody>
EOF

  while IFS='|' read -r server_name ilo_host status name serial model media_type capacity endurance health state message drive_uri check_time; do
    local cls
    cls="$(status_class "$status")"

    cat >> "$HTML_REPORT" <<EOF
<tr>
  <td>$(echo "$server_name" | html_escape)</td>
  <td>$(echo "$ilo_host" | html_escape)</td>
  <td><span class="${cls}">$(echo "$status" | html_escape)</span></td>
  <td>$(echo "$name" | html_escape)</td>
  <td>$(echo "$serial" | html_escape)</td>
  <td>$(echo "$model" | html_escape)</td>
  <td>$(echo "$media_type" | html_escape)</td>
  <td>$(echo "$capacity" | html_escape)</td>
  <td>$(echo "$endurance" | html_escape)</td>
  <td>$(echo "$health" | html_escape)</td>
  <td>$(echo "$state" | html_escape)</td>
  <td>$(echo "$message" | html_escape)</td>
  <td class="uri">$(echo "$drive_uri" | html_escape)</td>
  <td>$(echo "$check_time" | html_escape)</td>
</tr>
EOF
  done < "$TMP_DETAIL"

  cat >> "$HTML_REPORT" <<EOF
</tbody>
</table>

<div class="footer">
Report generated by check_redfish_ssd_endurance_batch_v3.sh
</div>

</body>
</html>
EOF
}

while getopts "f:w:c:o:t:h" opt; do
  case "$opt" in
    f) SERVER_FILE="$OPTARG" ;;
    w) WARN="$OPTARG" ;;
    c) CRIT="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    t) CURL_TIMEOUT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 3 ;;
  esac
done

if [[ ! -f "$SERVER_FILE" ]]; then
  echo "UNKNOWN - servers.ini file not found: $SERVER_FILE"
  exit 3
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "UNKNOWN - curl command not found"
  exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "UNKNOWN - jq command not found"
  exit 3
fi

if ! [[ "$WARN" =~ ^[0-9]+$ && "$CRIT" =~ ^[0-9]+$ ]]; then
  echo "UNKNOWN - warning and critical thresholds must be numeric"
  exit 3
fi

if (( WARN >= CRIT )); then
  echo "UNKNOWN - warning threshold must be lower than critical threshold"
  exit 3
fi

mkdir -p "$OUTDIR"

HTML_REPORT="${OUTDIR}/redfish_ssd_endurance_report_${REPORT_DATE}.html"
CSV_REPORT="${OUTDIR}/redfish_ssd_endurance_detail_${REPORT_DATE}.csv"

while IFS='|' read -r server_name ilo_host ilo_user ilo_pass extra; do
  # Skip blank lines and comments
  [[ -z "$server_name" ]] && continue
  [[ "$server_name" =~ ^[[:space:]]*# ]] && continue

  server_name="$(echo "$server_name" | xargs)"
  ilo_host="$(echo "$ilo_host" | xargs)"
  ilo_user="$(echo "$ilo_user" | xargs)"
  ilo_pass="$(echo "$ilo_pass" | xargs)"

  if [[ -z "$server_name" || -z "$ilo_host" || -z "$ilo_user" || -z "$ilo_pass" ]]; then
    TOTAL_SERVERS=$((TOTAL_SERVERS + 1))
    UNKNOWN_SERVERS=$((UNKNOWN_SERVERS + 1))
    set_global_status 3

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "${server_name:-UNKNOWN}" "${ilo_host:-UNKNOWN}" "UNKNOWN" 0 0 0 0 1 "Invalid servers.ini line" >> "$TMP_SUMMARY"

    continue
  fi

  echo "[INFO] Checking ${server_name} / ${ilo_host} ..."
  check_one_server "$server_name" "$ilo_host" "$ilo_user" "$ilo_pass"

done < "$SERVER_FILE"

generate_csv
generate_html

rm -f "$TMP_DETAIL" "$TMP_SUMMARY"

case "$GLOBAL_STATUS" in
  0)
    echo "OK - all servers SSD endurance are below ${WARN}% | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  1)
    echo "WARNING - one or more SSD endurance values are >= ${WARN}% | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  2)
    echo "CRITICAL - one or more SSD endurance values are >= ${CRIT}% | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  *)
    echo "UNKNOWN - one or more servers failed to query or no valid SSD endurance data found | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
esac

echo "HTML report: ${HTML_REPORT}"
echo "CSV report : ${CSV_REPORT}"

exit "$GLOBAL_STATUS"
