#!/bin/bash
#
# check_dell_redfish_ssd_endurance_batch_v1.sh
#
# Purpose:
#   Query multiple Dell PowerEdge iDRAC Redfish servers from servers.ini.
#   Designed for Dell PowerEdge R740 / R740xd.
#   Check physical disk SSD endurance and health.
#   Generate HTML summary/detail report and CSV detail report.
#   Support parallel host checking.
#
# servers.ini format:
#   name|idrac_ip|user|password
#
# Example:
#   dell-r740-01|192.168.1.101|root|calvin
#
# Exit code:
#   0 = OK
#   1 = WARNING
#   2 = CRITICAL
#   3 = UNKNOWN
#
# Meaning:
#   SSD Used % = SSD endurance used percentage.
#   Higher value means more SSD wear.
#
# Dell / Redfish common fields:
#   PredictedMediaLifeLeftPercent = life-left percent
#   SSD Used % = 100 - PredictedMediaLifeLeftPercent
#
# Common Dell iDRAC Redfish paths:
#   /redfish/v1/Systems
#   /redfish/v1/Systems/System.Embedded.1/Storage
#   /redfish/v1/Systems/System.Embedded.1/Storage/<controller>
#   /redfish/v1/Systems/System.Embedded.1/Storage/<controller>/Drives/<disk>
#

set -o pipefail

SERVER_FILE="idrac_servers.ini"
WARN=70
CRIT=85
CURL_TIMEOUT=25
PARALLEL_JOBS=8
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
JOB_ROOT=""

usage() {
  cat <<EOF
Usage:
  $0 -f <servers.ini> [-w warn_percent] [-c crit_percent] [-o output_dir] [-t timeout] [-j parallel_jobs]

Example:
  $0 -f servers.ini -w 70 -c 85 -o ./report -j 8

servers.ini format:
  name|idrac_ip|user|password

Example:
  dell-r740-01|192.168.1.101|root|calvin
  dell-r740xd-01|192.168.1.102|root|calvin

Options:
  -f  servers.ini file
  -w  warning threshold for SSD used percent, default: 70
  -c  critical threshold for SSD used percent, default: 85
  -o  output directory, default: ./report
  -t  curl timeout seconds, default: 25
  -j  parallel jobs, default: 8

Meaning:
  SSD Used % = SSD endurance used percentage.
  Higher value means more SSD wear.

Parallel:
  -j 1   = sequential style
  -j 5   = conservative
  -j 8   = recommended
  -j 12  = faster, but old iDRAC may timeout more easily
EOF
}

cleanup() {
  rm -f "$TMP_DETAIL" "$TMP_SUMMARY"

  if [[ -n "$JOB_ROOT" && -d "$JOB_ROOT" ]]; then
    rm -rf "$JOB_ROOT"
  fi
}
trap cleanup EXIT

html_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&#39;/g"
}

csv_quote() {
  local v="$1"
  v="${v//\"/\"\"}"
  printf '"%s"' "$v"
}

redfish_get() {
  local host="$1"
  local user="$2"
  local pass="$3"
  local uri="$4"

  curl ${INSECURE} -sS \
    --connect-timeout "${CURL_TIMEOUT}" \
    --max-time "${CURL_TIMEOUT}" \
    -u "${user}:${pass}" \
    -H "Accept: application/json" \
    "https://${host}${uri}" 2>/dev/null
}

is_json_ok() {
  jq empty >/dev/null 2>&1
}

get_collection_members() {
  jq -r '
    (
      .Members[]?."@odata.id" //
      .links.Member[]?.href //
      .Links.Member[]?.href //
      .Items[]?."@odata.id" //
      .items[]?."@odata.id" //
      .Items[]?.links.self.href //
      .items[]?.links.self.href //
      empty
    )
  ' 2>/dev/null
}

safe_field() {
  local v="$1"

  v="$(echo "$v" | tr '\r\n|' '   ' | awk '{$1=$1;print}')"

  if [[ -z "$v" || "$v" == "null" ]]; then
    echo "UNKNOWN"
  else
    echo "$v"
  fi
}

normalize_percent_number() {
  local v="$1"

  v="$(echo "$v" | tr -d '%' | awk '{$1=$1;print}')"

  if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v n="$v" 'BEGIN { printf "%.0f", n }'
    return 0
  fi

  return 1
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

###############################################################################
# Extract SSD endurance used percentage.
#
# Output:
#   used_percent|source|message
#
# Dell / iDRAC commonly exposes life-left style fields:
#   PredictedMediaLifeLeftPercent
#
# Convert:
#   SSD Used % = 100 - life_left_percent
###############################################################################
extract_endurance_used() {
  local json="$1"
  local raw=""
  local used=""

  ###########################################################################
  # 1. Redfish standard / Dell common life-left field
  ###########################################################################
  raw="$(echo "$json" | jq -r '
    [
      .. | objects
      | .PredictedMediaLifeLeftPercent?
      | select(. != null)
    ][0] // empty
  ' 2>/dev/null)"

  if [[ -n "$raw" && "$raw" != "null" ]]; then
    local left
    left="$(normalize_percent_number "$raw" 2>/dev/null)"

    if [[ "$left" =~ ^[0-9]+$ ]]; then
      if (( left < 0 )); then
        left=0
      fi

      if (( left > 100 )); then
        left=100
      fi

      used=$((100 - left))
      echo "${used}|PredictedMediaLifeLeftPercent|converted from life-left percent"
      return 0
    fi
  fi

  ###########################################################################
  # 2. Other possible life-left fields
  ###########################################################################
  raw="$(echo "$json" | jq -r '
    [
      .. | objects
      | (
          .MediaLifeLeftPercent? //
          .LifeLeftPercent? //
          .RemainingLifePercent? //
          .RemainingRatedWriteEndurance? //
          .SSDEnduranceLeftPercent? //
          .PredictedMediaLifeLeftPercentage?
        )
      | select(. != null)
    ][0] // empty
  ' 2>/dev/null)"

  if [[ -n "$raw" && "$raw" != "null" ]]; then
    local left
    left="$(normalize_percent_number "$raw" 2>/dev/null)"

    if [[ "$left" =~ ^[0-9]+$ ]]; then
      if (( left < 0 )); then
        left=0
      fi

      if (( left > 100 )); then
        left=100
      fi

      used=$((100 - left))
      echo "${used}|life-left-compatible-field|converted from life-left percent"
      return 0
    fi
  fi

  ###########################################################################
  # 3. Used-percent style fields
  ###########################################################################
  raw="$(echo "$json" | jq -r '
    [
      .. | objects
      | (
          .SSDEnduranceUtilizationPercentage? //
          .PercentageLifeUsed? //
          .PercentUsed? //
          .PercentageUsed? //
          .MediaLifeUsedPercent? //
          .LifeUsedPercent? //
          .WearPercent? //
          .WearLevelPercent? //
          .SSDPercentUsed? //
          .SSDMediaWearPercent?
        )
      | select(. != null)
    ][0] // empty
  ' 2>/dev/null)"

  if [[ -n "$raw" && "$raw" != "null" ]]; then
    used="$(normalize_percent_number "$raw" 2>/dev/null)"

    if [[ "$used" =~ ^[0-9]+$ ]]; then
      echo "${used}|used-percent-compatible-field|direct used percent"
      return 0
    fi
  fi

  echo "UNKNOWN|none|no supported SSD endurance or life-left field found"
  return 1
}

###############################################################################
# Discover Dell physical drive URIs.
#
# Main Dell path:
#   /redfish/v1/Systems
#   /redfish/v1/Systems/<system>/Storage
#   /redfish/v1/Systems/<system>/Storage/<storage_controller>
#   Drives[] or Drives {"@odata.id": "..."}
#
# Also attempts Chassis Drive collection as fallback.
###############################################################################
get_drive_uris_for_server() {
  local host="$1"
  local user="$2"
  local pass="$3"

  local drive_uris=""
  local systems_json
  local system_uris
  local system_uri

  systems_json="$(redfish_get "$host" "$user" "$pass" "/redfish/v1/Systems")"

  if ! echo "$systems_json" | is_json_ok; then
    return 1
  fi

  system_uris="$(echo "$systems_json" | get_collection_members)"

  if [[ -z "$system_uris" ]]; then
    return 1
  fi

  ###########################################################################
  # Method 1: Standard Redfish Storage model
  ###########################################################################
  for system_uri in $system_uris; do
    local storage_uri
    local storage_json
    local storage_members
    local storage_member_uri

    storage_uri="${system_uri%/}/Storage"
    storage_json="$(redfish_get "$host" "$user" "$pass" "$storage_uri")"

    if ! echo "$storage_json" | is_json_ok; then
      continue
    fi

    storage_members="$(echo "$storage_json" | get_collection_members)"

    for storage_member_uri in $storage_members; do
      local storage_member_json
      local found_drives
      local drives_collection_uri
      local drives_collection_json

      storage_member_json="$(redfish_get "$host" "$user" "$pass" "$storage_member_uri")"

      if ! echo "$storage_member_json" | is_json_ok; then
        continue
      fi

      #######################################################################
      # Case A:
      #   "Drives": [
      #     {"@odata.id": "/redfish/v1/Systems/.../Storage/.../Drives/..."}
      #   ]
      #######################################################################
      found_drives="$(echo "$storage_member_json" | jq -r '
        if (.Drives | type) == "array" then
          .Drives[]?."@odata.id" // empty
        else
          empty
        end
      ' 2>/dev/null)"

      if [[ -n "$found_drives" ]]; then
        drive_uris="${drive_uris}
${found_drives}"
      fi

      #######################################################################
      # Case B:
      #   "Drives": {
      #     "@odata.id": "/redfish/v1/Systems/.../Storage/.../Drives"
      #   }
      #######################################################################
      drives_collection_uri="$(echo "$storage_member_json" | jq -r '
        if (.Drives | type) == "object" then
          .Drives."@odata.id" // empty
        else
          empty
        end
      ' 2>/dev/null)"

      if [[ -n "$drives_collection_uri" ]]; then
        drives_collection_json="$(redfish_get "$host" "$user" "$pass" "$drives_collection_uri")"

        if echo "$drives_collection_json" | is_json_ok; then
          found_drives="$(echo "$drives_collection_json" | get_collection_members)"

          if [[ -n "$found_drives" ]]; then
            drive_uris="${drive_uris}
${found_drives}"
          fi
        fi
      fi
    done
  done

  ###########################################################################
  # Method 2: Chassis Drives fallback
  ###########################################################################
  local chassis_json
  local chassis_uris
  local chassis_uri

  chassis_json="$(redfish_get "$host" "$user" "$pass" "/redfish/v1/Chassis")"

  if echo "$chassis_json" | is_json_ok; then
    chassis_uris="$(echo "$chassis_json" | get_collection_members)"

    for chassis_uri in $chassis_uris; do
      local chassis_member_json
      local drives_collection_uri
      local drives_collection_json
      local found_drives

      chassis_member_json="$(redfish_get "$host" "$user" "$pass" "$chassis_uri")"

      if ! echo "$chassis_member_json" | is_json_ok; then
        continue
      fi

      drives_collection_uri="$(echo "$chassis_member_json" | jq -r '
        if (.Drives | type) == "object" then
          .Drives."@odata.id" // empty
        elif (.Links.Drives | type) == "object" then
          .Links.Drives."@odata.id" // empty
        else
          empty
        end
      ' 2>/dev/null)"

      if [[ -n "$drives_collection_uri" ]]; then
        drives_collection_json="$(redfish_get "$host" "$user" "$pass" "$drives_collection_uri")"

        if echo "$drives_collection_json" | is_json_ok; then
          found_drives="$(echo "$drives_collection_json" | get_collection_members)"

          if [[ -n "$found_drives" ]]; then
            drive_uris="${drive_uris}
${found_drives}"
          fi
        fi
      fi
    done
  fi

  echo "$drive_uris" | sed '/^[[:space:]]*$/d' | sort -u
  return 0
}

candidate_score() {
  local drive_status="$1"
  local capacity="$2"
  local endurance="$3"
  local endurance_source="$4"
  local name="$5"
  local model="$6"
  local serial="$7"
  local health="$8"
  local drive_uri="$9"

  local score=0

  if [[ "$endurance" =~ ^[0-9]+$ ]]; then
    score=$((score + 1000))
  fi

  if [[ "$drive_status" == "OK" || "$drive_status" == "WARNING" || "$drive_status" == "CRITICAL" ]]; then
    score=$((score + 500))
  fi

  if [[ "$capacity" != "UNKNOWN" ]]; then
    score=$((score + 200))
  fi

  case "$endurance_source" in
    PredictedMediaLifeLeftPercent)
      score=$((score + 100))
      ;;
    life-left-compatible-field)
      score=$((score + 90))
      ;;
    used-percent-compatible-field)
      score=$((score + 80))
      ;;
  esac

  if [[ "$drive_uri" == *"/Storage/"* || "$drive_uri" == *"/Drives/"* || "$drive_uri" == *"/Chassis/"* ]]; then
    score=$((score + 40))
  fi

  if [[ "$name" != "UNKNOWN" && "$name" != "UnknownDrive" && "$name" != "Empty Bay" ]]; then
    score=$((score + 20))
  fi

  if [[ "$model" != "UNKNOWN" && "$model" != "UnknownModel" ]]; then
    score=$((score + 10))
  fi

  if [[ "$serial" != "UNKNOWN" && "$serial" != "UnknownSerial" ]]; then
    score=$((score + 10))
  fi

  if [[ "$health" == "OK" ]]; then
    score=$((score + 5))
  fi

  echo "$score"
}

write_server_summary_once() {
  local summary_file="$1"
  local server_name="$2"
  local idrac_host="$3"
  local server_status="$4"
  local server_total="$5"
  local server_ok="$6"
  local server_warn="$7"
  local server_crit="$8"
  local server_unknown="$9"
  local message="${10}"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$server_name" "$idrac_host" "$server_status" "$server_total" "$server_ok" "$server_warn" "$server_crit" "$server_unknown" "$message" >> "$summary_file"
}

check_one_server() {
  local server_name="$1"
  local idrac_host="$2"
  local idrac_user="$3"
  local idrac_pass="$4"

  local server_status="OK"
  local server_code=0
  local server_total=0
  local server_ok=0
  local server_warn=0
  local server_crit=0
  local server_unknown=0
  local drive_uris
  local rc

  local tmp_candidates
  local tmp_final

  tmp_candidates="$(mktemp)"
  tmp_final="$(mktemp)"

  drive_uris="$(get_drive_uris_for_server "$idrac_host" "$idrac_user" "$idrac_pass")"
  rc=$?

  if (( rc != 0 )) || [[ -z "$drive_uris" ]]; then
    server_status="UNKNOWN"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$idrac_host" "UNKNOWN" "NO_DATA" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "No Redfish drive URI found or API failed" "-" "$(date '+%F %T')" >> "$TMP_DETAIL"

    write_server_summary_once "$TMP_SUMMARY" \
      "$server_name" "$idrac_host" "$server_status" 0 0 0 0 1 \
      "No Redfish drive URI found or API failed"

    rm -f "$tmp_candidates" "$tmp_final"
    return
  fi

  while read -r drive_uri; do
    [[ -z "$drive_uri" ]] && continue

    local drive_json
    local endurance_result
    local endurance
    local endurance_source
    local endurance_note
    local name
    local model
    local serial
    local media_type
    local health
    local state
    local capacity
    local protocol
    local manufacturer
    local failure_predicted
    local drive_status
    local message
    local score
    local dedup_key
    local check_time

    drive_json="$(redfish_get "$idrac_host" "$idrac_user" "$idrac_pass" "$drive_uri")"
    check_time="$(date '+%F %T')"

    if ! echo "$drive_json" | is_json_ok; then
      drive_status="UNKNOWN"
      message="Invalid JSON or API error"
      endurance="UNKNOWN"
      endurance_source="none"
      endurance_note="invalid response"
      name="UNKNOWN"
      model="UNKNOWN"
      serial="UNKNOWN"
      media_type="UNKNOWN"
      health="UNKNOWN"
      state="UNKNOWN"
      capacity="UNKNOWN"
      protocol="UNKNOWN"
      manufacturer="UNKNOWN"
      failure_predicted="UNKNOWN"
    else
      endurance_result="$(extract_endurance_used "$drive_json")"
      endurance="$(echo "$endurance_result" | awk -F'|' '{print $1}')"
      endurance_source="$(echo "$endurance_result" | awk -F'|' '{print $2}')"
      endurance_note="$(echo "$endurance_result" | awk -F'|' '{print $3}')"

      name="$(safe_field "$(echo "$drive_json" | jq -r '
        .Name //
        .name //
        .Id //
        .id //
        .DeviceName //
        .deviceName //
        .Description //
        "UnknownDrive"
      ' 2>/dev/null)")"

      model="$(safe_field "$(echo "$drive_json" | jq -r '
        .Model //
        .model //
        .PartNumber //
        .partNumber //
        .ProductName //
        .productName //
        "UnknownModel"
      ' 2>/dev/null)")"

      serial="$(safe_field "$(echo "$drive_json" | jq -r '
        .SerialNumber //
        .serialNumber //
        .SerialNo //
        .serialNo //
        .Serial //
        .serial //
        "UnknownSerial"
      ' 2>/dev/null)")"

      media_type="$(safe_field "$(echo "$drive_json" | jq -r '
        .MediaType //
        .mediaType //
        .Media //
        .media //
        "UnknownMedia"
      ' 2>/dev/null)")"

      health="$(safe_field "$(echo "$drive_json" | jq -r '
        .Status.Health //
        .status.health //
        .Health //
        .health //
        "UnknownHealth"
      ' 2>/dev/null)")"

      state="$(safe_field "$(echo "$drive_json" | jq -r '
        .Status.State //
        .status.state //
        .State //
        .state //
        "UnknownState"
      ' 2>/dev/null)")"

      protocol="$(safe_field "$(echo "$drive_json" | jq -r '
        .Protocol //
        .protocol //
        .SlotCapableProtocols[0]? //
        "UNKNOWN"
      ' 2>/dev/null)")"

      manufacturer="$(safe_field "$(echo "$drive_json" | jq -r '
        .Manufacturer //
        .manufacturer //
        "UNKNOWN"
      ' 2>/dev/null)")"

      failure_predicted="$(safe_field "$(echo "$drive_json" | jq -r '
        .FailurePredicted //
        .failurePredicted //
        "UNKNOWN"
      ' 2>/dev/null)")"

      capacity="$(echo "$drive_json" | jq -r '
        .CapacityBytes //
        .capacityBytes //
        .CapacityMiB //
        .capacityMiB //
        .CapacityMB //
        .capacityMB //
        empty
      ' 2>/dev/null | head -n 1)"

      if [[ -n "$capacity" && "$capacity" != "null" && "$capacity" =~ ^[0-9]+$ ]]; then
        if echo "$drive_json" | jq -e 'has("CapacityMiB") or has("capacityMiB")' >/dev/null 2>&1; then
          capacity="$(awk -v m="$capacity" 'BEGIN { printf "%.2f GB", m/1024 }')"
        elif echo "$drive_json" | jq -e 'has("CapacityMB") or has("capacityMB")' >/dev/null 2>&1; then
          capacity="$(awk -v m="$capacity" 'BEGIN { printf "%.2f GB", m/1024 }')"
        else
          capacity="$(awk -v b="$capacity" 'BEGIN { printf "%.2f GB", b/1024/1024/1024 }')"
        fi
      else
        capacity="UNKNOWN"
      fi

      #######################################################################
      # Skip empty / absent / disabled bays.
      #######################################################################
      if [[ "$state" == "Absent" || "$state" == "UnavailableOffline" || "$state" == "Disabled" ]]; then
        continue
      fi

      if [[ "$name" == "Empty Bay" || "$name" == "UNKNOWN" || "$name" == "UnknownDrive" ]]; then
        if [[ "$serial" == "UNKNOWN" || "$serial" == "UnknownSerial" ]]; then
          continue
        fi
      fi

      if [[ "$serial" == "UNKNOWN" || "$serial" == "UnknownSerial" ]]; then
        if [[ "$capacity" == "UNKNOWN" && "$endurance" == "UNKNOWN" ]]; then
          continue
        fi
      fi

      #######################################################################
      # SSD only.
      #######################################################################
      if [[ "$media_type" != "SSD" && "$media_type" != "UnknownMedia" && "$media_type" != "UNKNOWN" ]]; then
        continue
      fi

      if [[ "$media_type" == "UnknownMedia" || "$media_type" == "UNKNOWN" ]]; then
        if [[ "$endurance" == "UNKNOWN" && "$capacity" == "UNKNOWN" ]]; then
          continue
        fi
      fi

      #######################################################################
      # Status decision:
      # 1. Disk health/failure has priority.
      # 2. SSD endurance threshold next.
      #######################################################################
      if [[ "$failure_predicted" == "true" || "$failure_predicted" == "True" ]]; then
        drive_status="CRITICAL"
        message="Disk FailurePredicted=true; health=${health}; state=${state}"
      elif [[ "$health" == "Critical" || "$health" == "CRITICAL" ]]; then
        drive_status="CRITICAL"
        message="Disk health is Critical; state=${state}"
      elif [[ "$health" == "Warning" || "$health" == "WARNING" ]]; then
        drive_status="WARNING"
        message="Disk health is Warning; state=${state}"
      elif [[ "$endurance" == "UNKNOWN" || -z "$endurance" ]]; then
        drive_status="UNKNOWN"
        message="No supported SSD endurance field found; health=${health}; state=${state}"
      elif ! [[ "$endurance" =~ ^[0-9]+$ ]]; then
        drive_status="UNKNOWN"
        message="Invalid endurance value; health=${health}; state=${state}"
        endurance_source="invalid"
      elif (( endurance >= CRIT )); then
        drive_status="CRITICAL"
        message="SSD endurance used >= critical threshold; source=${endurance_source}; ${endurance_note}; health=${health}; state=${state}"
      elif (( endurance >= WARN )); then
        drive_status="WARNING"
        message="SSD endurance used >= warning threshold; source=${endurance_source}; ${endurance_note}; health=${health}; state=${state}"
      else
        drive_status="OK"
        message="SSD endurance and disk health OK; source=${endurance_source}; ${endurance_note}; health=${health}; state=${state}"
      fi
    fi

    if [[ "$serial" != "UNKNOWN" && "$serial" != "UnknownSerial" && -n "$serial" ]]; then
      dedup_key="$serial"
    else
      dedup_key="URI:${drive_uri}"
    fi

    score="$(candidate_score "$drive_status" "$capacity" "$endurance" "$endurance_source" "$name" "$model" "$serial" "$health" "$drive_uri")"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$dedup_key" "$score" "$server_name" "$idrac_host" "$drive_status" "$name" "$serial" "$model" "$media_type" \
      "$capacity" "$endurance" "$endurance_source" "$health" "$state" "$failure_predicted" "$protocol" "$manufacturer" \
      "$message" "$drive_uri" "$check_time" "END" >> "$tmp_candidates"

  done <<< "$drive_uris"

  if [[ -s "$tmp_candidates" ]]; then
    awk -F'|' '
      {
        key=$1
        score=$2+0
        if (!(key in best) || score > best[key]) {
          best[key]=score
          line[key]=$0
        }
      }
      END {
        for (key in line) {
          print line[key]
        }
      }
    ' "$tmp_candidates" | sort -t'|' -k3,3 -k7,7 > "$tmp_final"
  fi

  if [[ ! -s "$tmp_final" ]]; then
    server_status="UNKNOWN"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$idrac_host" "UNKNOWN" "NO_DATA" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "No populated SSD drive data found after filtering empty bays" "-" "$(date '+%F %T')" "END" >> "$TMP_DETAIL"

    write_server_summary_once "$TMP_SUMMARY" \
      "$server_name" "$idrac_host" "$server_status" 0 0 0 0 1 \
      "No populated SSD drive data found after filtering empty bays"

    rm -f "$tmp_candidates" "$tmp_final"
    return
  fi

  while IFS='|' read -r dedup_key score server_name_f idrac_host_f drive_status name serial model media_type capacity endurance endurance_source health state failure_predicted protocol manufacturer message drive_uri check_time marker; do
    server_total=$((server_total + 1))

    case "$drive_status" in
      CRITICAL)
        server_crit=$((server_crit + 1))
        server_code=2
        ;;
      WARNING)
        server_warn=$((server_warn + 1))
        if (( server_code < 1 )); then
          server_code=1
        fi
        ;;
      OK)
        server_ok=$((server_ok + 1))
        ;;
      *)
        server_unknown=$((server_unknown + 1))
        if (( server_code < 3 )); then
          server_code=3
        fi
        ;;
    esac

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name_f" "$idrac_host_f" "$drive_status" "$name" "$serial" "$model" "$media_type" \
      "$capacity" "$endurance" "$endurance_source" "$health" "$state" "$failure_predicted" "$protocol" "$manufacturer" \
      "$message" "$drive_uri" "$check_time" "END" >> "$TMP_DETAIL"

  done < "$tmp_final"

  if (( server_code == 2 )); then
    server_status="CRITICAL"
  elif (( server_code == 1 )); then
    server_status="WARNING"
  elif (( server_code == 3 )); then
    server_status="UNKNOWN"
  else
    server_status="OK"
  fi

  write_server_summary_once "$TMP_SUMMARY" \
    "$server_name" "$idrac_host" "$server_status" "$server_total" "$server_ok" "$server_warn" "$server_crit" "$server_unknown" "Completed"

  rm -f "$tmp_candidates" "$tmp_final"
}

safe_job_name() {
  local idx="$1"
  local server_name="$2"
  local host="$3"

  echo "${idx}_${server_name}_${host}" \
    | sed 's/[^A-Za-z0-9_.-]/_/g'
}

throttle_jobs() {
  local max_jobs="$1"

  while true; do
    local running
    running="$(jobs -rp | wc -l)"

    if (( running < max_jobs )); then
      break
    fi

    sleep 0.2
  done
}

run_host_job_parallel() {
  local idx="$1"
  local server_name="$2"
  local idrac_host="$3"
  local idrac_user="$4"
  local idrac_pass="$5"
  local job_root="$6"

  local safe_name
  local job_detail
  local job_summary
  local job_log
  local job_rc

  safe_name="$(safe_job_name "$idx" "$server_name" "$idrac_host")"
  job_detail="${job_root}/detail_${safe_name}.tmp"
  job_summary="${job_root}/summary_${safe_name}.tmp"
  job_log="${job_root}/log_${safe_name}.txt"
  job_rc="${job_root}/rc_${safe_name}.txt"

  (
    TMP_DETAIL="$job_detail"
    TMP_SUMMARY="$job_summary"

    echo "[INFO] Checking ${server_name} / ${idrac_host} ..."
    check_one_server "$server_name" "$idrac_host" "$idrac_user" "$idrac_pass"

  ) > "$job_log" 2>&1

  echo "$?" > "$job_rc"
}

merge_parallel_results() {
  local job_root="$1"

  : > "$TMP_DETAIL"
  : > "$TMP_SUMMARY"

  find "$job_root" -type f -name 'summary_*.tmp' | sort | while read -r f; do
    cat "$f" >> "$TMP_SUMMARY"
  done

  find "$job_root" -type f -name 'detail_*.tmp' | sort | while read -r f; do
    cat "$f" >> "$TMP_DETAIL"
  done
}

print_parallel_logs() {
  local job_root="$1"

  find "$job_root" -type f -name 'log_*.txt' | sort | while read -r f; do
    cat "$f"
  done
}

recalculate_totals_from_summary() {
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

  if [[ ! -s "$TMP_SUMMARY" ]]; then
    GLOBAL_STATUS=3
    return
  fi

  while IFS='|' read -r server_name host status total ok warn crit unknown message; do
    [[ -z "$server_name" ]] && continue

    TOTAL_SERVERS=$((TOTAL_SERVERS + 1))

    case "$status" in
      OK)
        OK_SERVERS=$((OK_SERVERS + 1))
        ;;
      WARNING)
        WARN_SERVERS=$((WARN_SERVERS + 1))
        ;;
      CRITICAL)
        CRIT_SERVERS=$((CRIT_SERVERS + 1))
        ;;
      *)
        UNKNOWN_SERVERS=$((UNKNOWN_SERVERS + 1))
        ;;
    esac

    if [[ "$total" =~ ^[0-9]+$ ]]; then
      TOTAL_DISKS=$((TOTAL_DISKS + total))
    fi

    if [[ "$ok" =~ ^[0-9]+$ ]]; then
      OK_DISKS=$((OK_DISKS + ok))
    fi

    if [[ "$warn" =~ ^[0-9]+$ ]]; then
      WARN_DISKS=$((WARN_DISKS + warn))
    fi

    if [[ "$crit" =~ ^[0-9]+$ ]]; then
      CRIT_DISKS=$((CRIT_DISKS + crit))
    fi

    if [[ "$unknown" =~ ^[0-9]+$ ]]; then
      UNKNOWN_DISKS=$((UNKNOWN_DISKS + unknown))
    fi

  done < "$TMP_SUMMARY"

  if (( UNKNOWN_SERVERS > 0 || UNKNOWN_DISKS > 0 )); then
    GLOBAL_STATUS=3
  elif (( CRIT_SERVERS > 0 || CRIT_DISKS > 0 )); then
    GLOBAL_STATUS=2
  elif (( WARN_SERVERS > 0 || WARN_DISKS > 0 )); then
    GLOBAL_STATUS=1
  else
    GLOBAL_STATUS=0
  fi
}

generate_csv() {
  {
    echo "ServerName,iDRACHost,Status,DriveName,Serial,Model,MediaType,Capacity,SSDUsedPercent,EnduranceSource,Health,State,FailurePredicted,Protocol,Manufacturer,Message,DriveURI,CheckTime"

    while IFS='|' read -r server_name host status name serial model media_type capacity endurance endurance_source health state failure_predicted protocol manufacturer message drive_uri check_time marker; do
      csv_quote "$server_name"; echo -n ","
      csv_quote "$host"; echo -n ","
      csv_quote "$status"; echo -n ","
      csv_quote "$name"; echo -n ","
      csv_quote "$serial"; echo -n ","
      csv_quote "$model"; echo -n ","
      csv_quote "$media_type"; echo -n ","
      csv_quote "$capacity"; echo -n ","
      csv_quote "$endurance"; echo -n ","
      csv_quote "$endurance_source"; echo -n ","
      csv_quote "$health"; echo -n ","
      csv_quote "$state"; echo -n ","
      csv_quote "$failure_predicted"; echo -n ","
      csv_quote "$protocol"; echo -n ","
      csv_quote "$manufacturer"; echo -n ","
      csv_quote "$message"; echo -n ","
      csv_quote "$drive_uri"; echo -n ","
      csv_quote "$check_time"
      echo
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
<title>Dell Redfish SSD Endurance Report</title>
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
  border-left: 6px solid #0672cb;
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

.table-wrap {
  overflow-x: auto;
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

<h1>Dell Redfish SSD Endurance Report</h1>
<div class="report-meta">
Generated Time: ${generated_time}<br>
Platform: Dell PowerEdge R740 / R740xd / iDRAC Redfish<br>
Warning Threshold: ${WARN}% &nbsp;&nbsp; Critical Threshold: ${CRIT}%<br>
Parallel Jobs: ${PARALLEL_JOBS}<br>
Compatible Paths: /redfish/v1/Systems/*/Storage and Chassis Drives fallback<br>
Supported Endurance Fields: PredictedMediaLifeLeftPercent / RemainingRatedWriteEndurance / used-percent-compatible fields<br>
Deduplication: Enabled by SerialNumber, best record selected automatically<br>
Empty Bay Filtering: Enabled<br>
Summary Integrity: Every servers.ini host is always shown
</div>

<div class="summary-cards">
  <div class="card"><div class="card-title">Total Servers</div><div class="card-value">${TOTAL_SERVERS}</div></div>
  <div class="card"><div class="card-title">OK Servers</div><div class="card-value">${OK_SERVERS}</div></div>
  <div class="card"><div class="card-title">Warning Servers</div><div class="card-value">${WARN_SERVERS}</div></div>
  <div class="card"><div class="card-title">Critical Servers</div><div class="card-value">${CRIT_SERVERS}</div></div>
  <div class="card"><div class="card-title">Unknown Servers</div><div class="card-value">${UNKNOWN_SERVERS}</div></div>
  <div class="card"><div class="card-title">Total Populated SSDs</div><div class="card-value">${TOTAL_DISKS}</div></div>
</div>

<h2>Server Summary</h2>
<div class="table-wrap">
<table>
<thead>
<tr>
  <th>Server Name</th>
  <th>iDRAC Host</th>
  <th>Status</th>
  <th>Total Populated SSD</th>
  <th>OK</th>
  <th>Warning</th>
  <th>Critical</th>
  <th>Unknown</th>
  <th>Message</th>
</tr>
</thead>
<tbody>
EOF

  while IFS='|' read -r server_name host status total ok warn crit unknown message; do
    local cls
    cls="$(status_class "$status")"

    cat >> "$HTML_REPORT" <<EOF
<tr>
  <td>$(echo "$server_name" | html_escape)</td>
  <td>$(echo "$host" | html_escape)</td>
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
</div>

<h2>SSD Drive Detail</h2>
<div class="table-wrap">
<table>
<thead>
<tr>
  <th>Server Name</th>
  <th>iDRAC Host</th>
  <th>Status</th>
  <th>Drive Name</th>
  <th>Serial</th>
  <th>Model</th>
  <th>Media</th>
  <th>Capacity</th>
  <th>SSD Used %</th>
  <th>Endurance Source</th>
  <th>Health</th>
  <th>State</th>
  <th>Failure Predicted</th>
  <th>Protocol</th>
  <th>Manufacturer</th>
  <th>Message</th>
  <th>Drive URI</th>
  <th>Check Time</th>
</tr>
</thead>
<tbody>
EOF

  while IFS='|' read -r server_name host status name serial model media_type capacity endurance endurance_source health state failure_predicted protocol manufacturer message drive_uri check_time marker; do
    local cls
    cls="$(status_class "$status")"

    cat >> "$HTML_REPORT" <<EOF
<tr>
  <td>$(echo "$server_name" | html_escape)</td>
  <td>$(echo "$host" | html_escape)</td>
  <td><span class="${cls}">$(echo "$status" | html_escape)</span></td>
  <td>$(echo "$name" | html_escape)</td>
  <td>$(echo "$serial" | html_escape)</td>
  <td>$(echo "$model" | html_escape)</td>
  <td>$(echo "$media_type" | html_escape)</td>
  <td>$(echo "$capacity" | html_escape)</td>
  <td>$(echo "$endurance" | html_escape)</td>
  <td>$(echo "$endurance_source" | html_escape)</td>
  <td>$(echo "$health" | html_escape)</td>
  <td>$(echo "$state" | html_escape)</td>
  <td>$(echo "$failure_predicted" | html_escape)</td>
  <td>$(echo "$protocol" | html_escape)</td>
  <td>$(echo "$manufacturer" | html_escape)</td>
  <td>$(echo "$message" | html_escape)</td>
  <td class="uri">$(echo "$drive_uri" | html_escape)</td>
  <td>$(echo "$check_time" | html_escape)</td>
</tr>
EOF
  done < "$TMP_DETAIL"

  cat >> "$HTML_REPORT" <<EOF
</tbody>
</table>
</div>

<div class="footer">
Report generated by check_dell_redfish_ssd_endurance_batch_v1.sh
</div>

</body>
</html>
EOF
}

###############################################################################
# Main
###############################################################################

while getopts "f:w:c:o:t:j:h" opt; do
  case "$opt" in
    f) SERVER_FILE="$OPTARG" ;;
    w) WARN="$OPTARG" ;;
    c) CRIT="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    t) CURL_TIMEOUT="$OPTARG" ;;
    j) PARALLEL_JOBS="$OPTARG" ;;
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

if ! [[ "$CURL_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "UNKNOWN - timeout must be numeric"
  exit 3
fi

if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]]; then
  echo "UNKNOWN - parallel jobs must be numeric"
  exit 3
fi

if (( PARALLEL_JOBS < 1 )); then
  PARALLEL_JOBS=1
fi

if (( PARALLEL_JOBS > 32 )); then
  echo "WARNING - parallel jobs too high, force limit to 32"
  PARALLEL_JOBS=32
fi

mkdir -p "$OUTDIR"

HTML_REPORT="${OUTDIR}/dell_redfish_ssd_endurance_report_${REPORT_DATE}.html"
CSV_REPORT="${OUTDIR}/dell_redfish_ssd_endurance_detail_${REPORT_DATE}.csv"

JOB_ROOT="$(mktemp -d)"

HOST_INDEX=0

echo "[INFO] Parallel jobs: ${PARALLEL_JOBS}"
echo "[INFO] Server file  : ${SERVER_FILE}"
echo "[INFO] Output dir   : ${OUTDIR}"

while IFS='|' read -r server_name idrac_host idrac_user idrac_pass extra; do
  [[ -z "$server_name" ]] && continue
  [[ "$server_name" =~ ^[[:space:]]*# ]] && continue

  server_name="$(echo "$server_name" | xargs)"
  idrac_host="$(echo "$idrac_host" | xargs)"
  idrac_user="$(echo "$idrac_user" | xargs)"
  idrac_pass="$(echo "$idrac_pass" | xargs)"

  HOST_INDEX=$((HOST_INDEX + 1))

  if [[ -z "$server_name" || -z "$idrac_host" || -z "$idrac_user" || -z "$idrac_pass" ]]; then
    safe_name="$(safe_job_name "$HOST_INDEX" "${server_name:-UNKNOWN}" "${idrac_host:-UNKNOWN}")"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "${server_name:-UNKNOWN}" "${idrac_host:-UNKNOWN}" "UNKNOWN" 0 0 0 0 1 "Invalid servers.ini line" \
      > "${JOB_ROOT}/summary_${safe_name}.tmp"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "${server_name:-UNKNOWN}" "${idrac_host:-UNKNOWN}" "UNKNOWN" "NO_DATA" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "Invalid servers.ini line" "-" "$(date '+%F %T')" "END" \
      > "${JOB_ROOT}/detail_${safe_name}.tmp"

    continue
  fi

  throttle_jobs "$PARALLEL_JOBS"

  run_host_job_parallel "$HOST_INDEX" "$server_name" "$idrac_host" "$idrac_user" "$idrac_pass" "$JOB_ROOT" &

done < "$SERVER_FILE"

wait

print_parallel_logs "$JOB_ROOT"

merge_parallel_results "$JOB_ROOT"

recalculate_totals_from_summary

generate_csv
generate_html

case "$GLOBAL_STATUS" in
  0)
    echo "OK - all Dell populated SSD endurance and health values are OK | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  1)
    echo "WARNING - one or more Dell populated SSD values are warning | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  2)
    echo "CRITICAL - one or more Dell populated SSD values are critical | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  *)
    echo "UNKNOWN - one or more Dell servers failed to query or no valid populated SSD data found | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
esac

echo "HTML report: ${HTML_REPORT}"
echo "CSV report : ${CSV_REPORT}"

recipients=(
    sys-linux@taifex.com.tw
    sys-op@taifex.com.tw
    sysalert@taifex.com.tw
)
 TO="${recipients[@]}"
#TO="jeffreyhu@taifex.com.tw"
XTAG="[OADMZ] Dell PowerEdge R740/R740xd Redfish SSD Endurance Healthy Report"
#/usr/local/bin/weasyprint "$OUT_HTML" "$OUT_PDF"
#echo "✅ PDF generated: $OUT_PDF"
#echo "請查收 ${XTAG}（PDF 附件）" | mailx -a "$OUT_PDF" -a "$OUT_HTML" -s "${XTAG}（Hosts=${TOTAL_HOSTS}, OK=${OK_HOSTS}, WARN=${WARN_HOSTS}, CRIT=${CRIT_HOSTS}, Drives=${TOTAL_DRIVES}, Unhealthy=${TOTAL_UNHEALTHY}, SSDAlerts=${TOTAL_SSD_ALERTS}）" $TO
echo "${XTAG}" | mailx -a "${HTML_REPORT}" -a "${CSV_REPORT}" -s "${XTAG} ( servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS} )" $TO

exit "$GLOBAL_STATUS"
