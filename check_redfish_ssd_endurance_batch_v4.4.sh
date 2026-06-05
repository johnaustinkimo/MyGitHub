#!/bin/bash
#
# check_redfish_ssd_endurance_batch_v4.4.sh
#
# Purpose:
#   Query multiple HPE iLO Redfish / iLO REST servers from servers.ini.
#   Compatible with iLO4 / iLO5 / iLO6 style storage paths.
#   Generate de-duplicated HTML summary/detail report and CSV detail report.
#
# servers.ini format:
#   name|ilo_ip|user|password
#
# Example:
#   stmr01|192.168.29.13|cose|YourPassword
#
# Exit code:
#   0 = OK
#   1 = WARNING
#   2 = CRITICAL
#   3 = UNKNOWN
#
# Notes:
#   iLO4 / iLO5 legacy SmartStorage:
#     SSDEnduranceUtilizationPercentage = SSD used percent
#
#   iLO6 / DMTF Drive:
#     PredictedMediaLifeLeftPercent = SSD life-left percent
#     SSD Used % = 100 - PredictedMediaLifeLeftPercent
#
# v4.4 Fix:
#   1. Add iLO4 legacy REST endpoint fallback:
#        /rest/v1/Systems/1/SmartStorage/ArrayControllers
#   2. Skip Empty Bay / Absent / UnknownSerial empty slots.
#   3. De-duplicate same physical disk by SerialNumber.
#   4. Prefer complete Storage/Chassis Drive data over legacy SmartStorage data.
#   5. Avoid counting empty bays as UNKNOWN SSDs.
#

set -o pipefail

SERVER_FILE="servers.ini"
WARN=70
CRIT=85
CURL_TIMEOUT=25
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
  stmr01|192.168.29.13|cose|YourPassword
  iLO-vcnu02|192.168.175.122|cose|YourPassword

Meaning:
  SSD Used % = SSD endurance used percentage.
  Higher value means more SSD wear.

Compatibility:
  iLO4 / iLO5 Redfish:
    /redfish/v1/Systems/1/SmartStorage/ArrayControllers/...

  iLO4 legacy REST:
    /rest/v1/Systems/1/SmartStorage/ArrayControllers/...

  iLO5 / iLO6 Storage:
    /redfish/v1/Systems/1/Storage/...

  iLO6 Chassis:
    /redfish/v1/Chassis/<id>/Drives/...

v4.4:
  Skip Empty Bay / Absent slots.
  De-duplicate same physical SSD by SerialNumber.
EOF
}

cleanup() {
  rm -f "$TMP_DETAIL" "$TMP_SUMMARY"
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

ilo4_rest_get() {
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

is_json_ok() {
  jq empty >/dev/null 2>&1
}

get_collection_members() {
  jq -r '
    (
      .Members[]?."@odata.id" //
      .links.Member[]?.href //
      .Links.Member[]?.href //
      .Items[]?.links.self.href //
      .items[]?.links.self.href //
      .Items[]?."@odata.id" //
      .items[]?."@odata.id" //
      empty
    )
  ' 2>/dev/null
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

safe_field() {
  local v="$1"

  v="$(echo "$v" | tr '\r\n|' '   ' | awk '{$1=$1;print}')"

  if [[ -z "$v" || "$v" == "null" ]]; then
    echo "UNKNOWN"
  else
    echo "$v"
  fi
}

###############################################################################
# Extract SSD endurance used percentage.
#
# Output format:
#   used_percent|source|message
###############################################################################
extract_endurance_used() {
  local json="$1"
  local raw=""
  local used=""

  ###########################################################################
  # 1. HPE iLO4 / iLO5 legacy SmartStorage field
  #    Meaning: SSD endurance used percent
  ###########################################################################
  raw="$(echo "$json" | jq -r '
    [
      .. | objects
      | .SSDEnduranceUtilizationPercentage?
      | select(. != null)
    ][0] // empty
  ' 2>/dev/null)"

  if [[ -n "$raw" && "$raw" != "null" ]]; then
    used="$(normalize_percent_number "$raw" 2>/dev/null)"

    if [[ "$used" =~ ^[0-9]+$ ]]; then
      echo "${used}|SSDEnduranceUtilizationPercentage|direct used percent"
      return 0
    fi
  fi

  ###########################################################################
  # 2. HPE iLO6 / DMTF Drive field
  #    Meaning: predicted media life left percent
  #
  #    SSD Used % = 100 - PredictedMediaLifeLeftPercent
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
  # 3. Other possible life-left fields
  ###########################################################################
  raw="$(echo "$json" | jq -r '
    [
      .. | objects
      | (
          .MediaLifeLeftPercent? //
          .LifeLeftPercent? //
          .RemainingLifePercent? //
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
  # 4. Other possible used-percent fields
  ###########################################################################
  raw="$(echo "$json" | jq -r '
    [
      .. | objects
      | (
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
# Discover drive URIs.
#
# Discovery order:
#   1. Redfish Systems discovery
#   2. iLO4/iLO5 Redfish SmartStorage
#   3. iLO4 legacy RESTful API SmartStorage fallback
#   4. Standard Redfish Storage model
#   5. iLO6 Chassis Drives path
#
# Safe handling for:
#   "Drives": [ {"@odata.id": "..."} ]
#   "Drives": { "@odata.id": "..." }
###############################################################################
get_drive_uris_for_server() {
  local ilo_host="$1"
  local ilo_user="$2"
  local ilo_pass="$3"

  local drive_uris=""
  local systems_json
  local system_uris
  local chassis_json
  local chassis_uris

  ###########################################################################
  # Method 1: Redfish Systems discovery
  ###########################################################################
  systems_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "/redfish/v1/Systems")"

  if echo "$systems_json" | is_json_ok; then
    system_uris="$(echo "$systems_json" | get_collection_members)"
  else
    system_uris=""
  fi

  ###########################################################################
  # Method 2: iLO4/iLO5 Redfish SmartStorage legacy path
  ###########################################################################
  if [[ -n "$system_uris" ]]; then
    local system_uri

    for system_uri in $system_uris; do
      local array_controllers_uri
      local array_controllers_json
      local controller_uris
      local controller_uri

      array_controllers_uri="${system_uri%/}/SmartStorage/ArrayControllers"
      array_controllers_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$array_controllers_uri")"

      if ! echo "$array_controllers_json" | is_json_ok; then
        continue
      fi

      controller_uris="$(echo "$array_controllers_json" | get_collection_members)"

      for controller_uri in $controller_uris; do
        local controller_json
        local pd_collection_uri
        local pd_collection_json
        local found_drives

        controller_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$controller_uri")"

        if ! echo "$controller_json" | is_json_ok; then
          continue
        fi

        pd_collection_uri="$(echo "$controller_json" | jq -r '
          .Links.PhysicalDrives."@odata.id" //
          .links.PhysicalDrives."@odata.id" //
          .links.PhysicalDrives.href //
          .Links.PhysicalDrives.href //
          .PhysicalDrives."@odata.id" //
          .PhysicalDrives.href //
          empty
        ' 2>/dev/null)"

        if [[ -n "$pd_collection_uri" ]]; then
          pd_collection_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$pd_collection_uri")"

          if echo "$pd_collection_json" | is_json_ok; then
            found_drives="$(echo "$pd_collection_json" | get_collection_members)"

            if [[ -n "$found_drives" ]]; then
              drive_uris="${drive_uris}
${found_drives}"
            fi
          fi
        fi
      done
    done
  fi

  ###########################################################################
  # Method 3: iLO4 legacy RESTful API SmartStorage fallback
  #
  # Some iLO4 firmware exposes SmartStorage under:
  #   /rest/v1/Systems/1/SmartStorage/ArrayControllers
  ###########################################################################
  local ilo4_array_json
  local ilo4_controller_uris
  local ilo4_controller_uri

  ilo4_array_json="$(ilo4_rest_get "$ilo_host" "$ilo_user" "$ilo_pass" "/rest/v1/Systems/1/SmartStorage/ArrayControllers")"

  if echo "$ilo4_array_json" | is_json_ok; then
    ilo4_controller_uris="$(echo "$ilo4_array_json" | get_collection_members)"

    for ilo4_controller_uri in $ilo4_controller_uris; do
      local ilo4_controller_json
      local ilo4_pd_collection_uri
      local ilo4_pd_collection_json
      local ilo4_found_drives

      ilo4_controller_json="$(ilo4_rest_get "$ilo_host" "$ilo_user" "$ilo_pass" "$ilo4_controller_uri")"

      if ! echo "$ilo4_controller_json" | is_json_ok; then
        continue
      fi

      ilo4_pd_collection_uri="$(echo "$ilo4_controller_json" | jq -r '
        .Links.PhysicalDrives."@odata.id" //
        .links.PhysicalDrives."@odata.id" //
        .links.PhysicalDrives.href //
        .Links.PhysicalDrives.href //
        .PhysicalDrives."@odata.id" //
        .PhysicalDrives.href //
        empty
      ' 2>/dev/null)"

      if [[ -n "$ilo4_pd_collection_uri" ]]; then
        ilo4_pd_collection_json="$(ilo4_rest_get "$ilo_host" "$ilo_user" "$ilo_pass" "$ilo4_pd_collection_uri")"

        if echo "$ilo4_pd_collection_json" | is_json_ok; then
          ilo4_found_drives="$(echo "$ilo4_pd_collection_json" | get_collection_members)"

          if [[ -n "$ilo4_found_drives" ]]; then
            drive_uris="${drive_uris}
${ilo4_found_drives}"
          fi
        fi
      fi
    done
  fi

  ###########################################################################
  # Method 4: Standard Redfish Storage model
  ###########################################################################
  if [[ -n "$system_uris" ]]; then
    local system_uri

    for system_uri in $system_uris; do
      local storage_uri
      local storage_json
      local storage_members
      local storage_member_uri

      storage_uri="${system_uri%/}/Storage"
      storage_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$storage_uri")"

      if ! echo "$storage_json" | is_json_ok; then
        continue
      fi

      storage_members="$(echo "$storage_json" | get_collection_members)"

      for storage_member_uri in $storage_members; do
        local storage_member_json
        local found_drives
        local drives_collection_uri
        local drives_collection_json

        storage_member_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$storage_member_uri")"

        if ! echo "$storage_member_json" | is_json_ok; then
          continue
        fi

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

        drives_collection_uri="$(echo "$storage_member_json" | jq -r '
          if (.Drives | type) == "object" then
            .Drives."@odata.id" // empty
          else
            empty
          end
        ' 2>/dev/null)"

        if [[ -n "$drives_collection_uri" ]]; then
          drives_collection_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$drives_collection_uri")"

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
  fi

  ###########################################################################
  # Method 5: iLO6 Chassis Drives path
  ###########################################################################
  chassis_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "/redfish/v1/Chassis")"

  if echo "$chassis_json" | is_json_ok; then
    chassis_uris="$(echo "$chassis_json" | get_collection_members)"

    if [[ -n "$chassis_uris" ]]; then
      local chassis_uri

      for chassis_uri in $chassis_uris; do
        local chassis_member_json
        local drives_collection_uri
        local drives_collection_json
        local found_drives

        chassis_member_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$chassis_uri")"

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
          drives_collection_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$drives_collection_uri")"

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
  fi

  echo "$drive_uris" | sed '/^[[:space:]]*$/d' | sort -u
  return 0
}

###############################################################################
# Calculate score for duplicate candidates.
#
# Higher score wins.
# Prefer:
#   1. Has valid endurance
#   2. Has known capacity
#   3. Has PredictedMediaLifeLeftPercent or other Storage/Chassis data
#   4. Has complete name/model/serial
#   5. Health OK
###############################################################################
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
    SSDEnduranceUtilizationPercentage)
      score=$((score + 50))
      ;;
  esac

  if [[ "$drive_uri" == *"/Storage/"* || "$drive_uri" == *"/Chassis/"* ]]; then
    score=$((score + 40))
  fi

  if [[ "$drive_uri" == *"/SmartStorage/"* ]]; then
    score=$((score + 10))
  fi

  if [[ "$drive_uri" == *"/rest/v1/"* ]]; then
    score=$((score + 5))
  fi

  if [[ "$name" != "UNKNOWN" && "$name" != "HpeSmartStorageDiskDrive" && "$name" != "Empty Bay" ]]; then
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

###############################################################################
# Check one server.
#
# v4.4 logic:
#   1. Discover all possible drive URIs.
#   2. Fetch all drive objects.
#   3. Skip Empty Bay / Absent / non-populated slots.
#   4. Skip non-SSD physical drives.
#   5. Build candidates.
#   6. De-duplicate by SerialNumber.
#   7. Keep best candidate per physical SSD.
#   8. Write summary and detail based on de-duplicated result only.
###############################################################################
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

  local tmp_candidates
  local tmp_final
  tmp_candidates="$(mktemp)"
  tmp_final="$(mktemp)"

  TOTAL_SERVERS=$((TOTAL_SERVERS + 1))

  drive_uris="$(get_drive_uris_for_server "$ilo_host" "$ilo_user" "$ilo_pass")"
  rc=$?

  if (( rc != 0 )) || [[ -z "$drive_uris" ]]; then
    server_status="UNKNOWN"
    UNKNOWN_SERVERS=$((UNKNOWN_SERVERS + 1))
    UNKNOWN_DISKS=$((UNKNOWN_DISKS + 1))
    set_global_status 3

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$ilo_host" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "No Redfish or iLO REST drive URI found or API failed" "-" "-" >> "$TMP_DETAIL"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$ilo_host" "$server_status" 0 0 0 0 1 "No drive data found" >> "$TMP_SUMMARY"

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
    local drive_status
    local message
    local score
    local dedup_key
    local check_time

    if [[ "$drive_uri" == /rest/v1/* ]]; then
      drive_json="$(ilo4_rest_get "$ilo_host" "$ilo_user" "$ilo_pass" "$drive_uri")"
    else
      drive_json="$(redfish_get "$ilo_host" "$ilo_user" "$ilo_pass" "$drive_uri")"
    fi

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
        "UnknownDrive"
      ' 2>/dev/null)")"

      model="$(safe_field "$(echo "$drive_json" | jq -r '
        .Model //
        .model //
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
      # v4.4:
      # Skip empty / absent / non-populated bays.
      # These are not failed SSDs and should not become UNKNOWN.
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
      # This script checks SSD endurance only.
      # Skip HDD / non-SSD / enclosure pseudo-drive objects.
      #
      # Keep UnknownMedia only when it has valid endurance or serial/capacity,
      # because some iLO4 legacy objects may not expose MediaType clearly.
      #######################################################################
      if [[ "$media_type" != "SSD" && "$media_type" != "UnknownMedia" && "$media_type" != "UNKNOWN" ]]; then
        continue
      fi

      if [[ "$media_type" == "UnknownMedia" || "$media_type" == "UNKNOWN" ]]; then
        if [[ "$endurance" == "UNKNOWN" && "$capacity" == "UNKNOWN" ]]; then
          continue
        fi
      fi

      if [[ "$endurance" == "UNKNOWN" || -z "$endurance" ]]; then
        drive_status="UNKNOWN"
        message="No supported SSD endurance field found"
      elif ! [[ "$endurance" =~ ^[0-9]+$ ]]; then
        drive_status="UNKNOWN"
        message="Invalid endurance value"
        endurance_source="invalid"
      elif (( endurance >= CRIT )); then
        drive_status="CRITICAL"
        message="SSD endurance used >= critical threshold; source=${endurance_source}; ${endurance_note}"
      elif (( endurance >= WARN )); then
        drive_status="WARNING"
        message="SSD endurance used >= warning threshold; source=${endurance_source}; ${endurance_note}"
      else
        drive_status="OK"
        message="SSD endurance used below warning threshold; source=${endurance_source}; ${endurance_note}"
      fi
    fi

    if [[ "$serial" != "UNKNOWN" && "$serial" != "UnknownSerial" && -n "$serial" ]]; then
      dedup_key="$serial"
    else
      dedup_key="URI:${drive_uri}"
    fi

    score="$(candidate_score "$drive_status" "$capacity" "$endurance" "$endurance_source" "$name" "$model" "$serial" "$health" "$drive_uri")"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$dedup_key" "$score" "$server_name" "$ilo_host" "$drive_status" "$name" "$serial" "$model" "$media_type" \
      "$capacity" "$endurance" "$endurance_source" "$health" "$state" "$message" "$drive_uri" "$check_time" >> "$tmp_candidates"

  done <<< "$drive_uris"

  ###########################################################################
  # De-duplicate candidates by key and keep highest score.
  ###########################################################################
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
    UNKNOWN_SERVERS=$((UNKNOWN_SERVERS + 1))
    UNKNOWN_DISKS=$((UNKNOWN_DISKS + 1))
    set_global_status 3

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$ilo_host" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" "UNKNOWN" \
      "No populated SSD drive data found after filtering empty bays" "-" "-" >> "$TMP_DETAIL"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name" "$ilo_host" "$server_status" 0 0 0 0 1 "No populated SSD drive data found" >> "$TMP_SUMMARY"

    rm -f "$tmp_candidates" "$tmp_final"
    return
  fi

  while IFS='|' read -r dedup_key score server_name_f ilo_host_f drive_status name serial model media_type capacity endurance endurance_source health state message drive_uri check_time; do
    server_total=$((server_total + 1))
    TOTAL_DISKS=$((TOTAL_DISKS + 1))

    case "$drive_status" in
      CRITICAL)
        server_crit=$((server_crit + 1))
        CRIT_DISKS=$((CRIT_DISKS + 1))
        server_code=2
        set_global_status 2
        ;;
      WARNING)
        server_warn=$((server_warn + 1))
        WARN_DISKS=$((WARN_DISKS + 1))
        if (( server_code < 1 )); then
          server_code=1
        fi
        set_global_status 1
        ;;
      OK)
        server_ok=$((server_ok + 1))
        OK_DISKS=$((OK_DISKS + 1))
        ;;
      *)
        server_unknown=$((server_unknown + 1))
        UNKNOWN_DISKS=$((UNKNOWN_DISKS + 1))
        if (( server_code < 3 )); then
          server_code=3
        fi
        set_global_status 3
        ;;
    esac

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$server_name_f" "$ilo_host_f" "$drive_status" "$name" "$serial" "$model" "$media_type" \
      "$capacity" "$endurance" "$endurance_source" "$health" "$state" "$message" "$drive_uri" "$check_time" >> "$TMP_DETAIL"

  done < "$tmp_final"

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

  rm -f "$tmp_candidates" "$tmp_final"
}

generate_csv() {
  {
    echo "ServerName,iLOHost,Status,DriveName,Serial,Model,MediaType,Capacity,SSDEnduranceUsedPercent,EnduranceSource,Health,State,Message,DriveURI,CheckTime"

    while IFS='|' read -r server_name ilo_host status name serial model media_type capacity endurance endurance_source health state message drive_uri check_time; do
      csv_quote "$server_name"; echo -n ","
      csv_quote "$ilo_host"; echo -n ","
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

<h1>Redfish SSD Endurance Report</h1>
<div class="report-meta">
Generated Time: ${generated_time}<br>
Warning Threshold: ${WARN}% &nbsp;&nbsp; Critical Threshold: ${CRIT}%<br>
Compatible Paths: Redfish SmartStorage / iLO4 REST SmartStorage / Storage / Chassis Drives<br>
Supported Endurance Fields: SSDEnduranceUtilizationPercentage / PredictedMediaLifeLeftPercent<br>
Deduplication: Enabled by SerialNumber, best record selected automatically<br>
Empty Bay Filtering: Enabled
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
  <th>iLO Host</th>
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
</div>

<h2>SSD Drive Detail</h2>
<div class="table-wrap">
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
  <th>Endurance Source</th>
  <th>Health</th>
  <th>State</th>
  <th>Message</th>
  <th>Drive URI</th>
  <th>Check Time</th>
</tr>
</thead>
<tbody>
EOF

  while IFS='|' read -r server_name ilo_host status name serial model media_type capacity endurance endurance_source health state message drive_uri check_time; do
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
  <td>$(echo "$endurance_source" | html_escape)</td>
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
</div>

<div class="footer">
Report generated by check_redfish_ssd_endurance_batch_v4.4.sh
</div>

</body>
</html>
EOF
}

###############################################################################
# Main
###############################################################################

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

case "$GLOBAL_STATUS" in
  0)
    echo "OK - all populated SSD endurance values are below ${WARN}% | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  1)
    echo "WARNING - one or more populated SSD endurance values are >= ${WARN}% | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  2)
    echo "CRITICAL - one or more populated SSD endurance values are >= ${CRIT}% | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
  *)
    echo "UNKNOWN - one or more servers failed to query or no valid populated SSD endurance data found | servers=${TOTAL_SERVERS} disks=${TOTAL_DISKS} ok_disks=${OK_DISKS} warn_disks=${WARN_DISKS} crit_disks=${CRIT_DISKS} unknown_disks=${UNKNOWN_DISKS}"
    ;;
esac

echo "HTML report: ${HTML_REPORT}"
echo "CSV report : ${CSV_REPORT}"

exit "$GLOBAL_STATUS"
