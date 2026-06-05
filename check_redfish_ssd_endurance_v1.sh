#!/bin/bash
#
# check_redfish_ssd_endurance_v1.sh
#
# Purpose:
#   Check all HPE iLO Redfish SmartStorage / Storage disk drives
#   and report SSDEnduranceUtilizationPercentage.
#
# Exit code:
#   0 = OK
#   1 = WARNING
#   2 = CRITICAL
#   3 = UNKNOWN
#
# Example:
#   ./check_redfish_ssd_endurance_v1.sh -H 192.168.1.10 -u Administrator -p 'password' -w 70 -c 85
#

set -o pipefail

ILO_HOST=""
ILO_USER=""
ILO_PASS=""
WARN=70
CRIT=85
CURL_TIMEOUT=20
INSECURE="-k"

usage() {
  cat <<EOF
Usage:
  $0 -H <ilo_ip_or_fqdn> -u <user> -p <password> [-w warn_percent] [-c crit_percent]

Example:
  $0 -H 192.168.1.10 -u Administrator -p 'password' -w 70 -c 85

Meaning:
  SSDEnduranceUtilizationPercentage = SSD endurance used percentage.
  Higher value means more SSD wear.
EOF
}

while getopts "H:u:p:w:c:t:h" opt; do
  case "$opt" in
    H) ILO_HOST="$OPTARG" ;;
    u) ILO_USER="$OPTARG" ;;
    p) ILO_PASS="$OPTARG" ;;
    w) WARN="$OPTARG" ;;
    c) CRIT="$OPTARG" ;;
    t) CURL_TIMEOUT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 3 ;;
  esac
done

if [[ -z "$ILO_HOST" || -z "$ILO_USER" || -z "$ILO_PASS" ]]; then
  usage
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

BASE_URL="https://${ILO_HOST}"

redfish_get() {
  local uri="$1"

  curl ${INSECURE} -sS \
    --connect-timeout "${CURL_TIMEOUT}" \
    --max-time "${CURL_TIMEOUT}" \
    -u "${ILO_USER}:${ILO_PASS}" \
    -H "Accept: application/json" \
    "${BASE_URL}${uri}"
}

get_json_value() {
  local json="$1"
  local filter="$2"

  echo "$json" | jq -r "$filter" 2>/dev/null
}

# Store discovered drive URIs here.
DRIVE_URIS=""

###############################################################################
# Method 1:
# Newer standard Redfish storage model:
#   /redfish/v1/Systems
#   /redfish/v1/Systems/<id>/Storage
#   /redfish/v1/Systems/<id>/Storage/<controller>
#   Drive links may point to /redfish/v1/Chassis/.../Drives/...
###############################################################################

SYSTEMS_JSON="$(redfish_get "/redfish/v1/Systems")"
if echo "$SYSTEMS_JSON" | jq empty >/dev/null 2>&1; then
  SYSTEM_URIS="$(echo "$SYSTEMS_JSON" | jq -r '.Members[]?."@odata.id"')"

  for SYSTEM_URI in $SYSTEM_URIS; do
    STORAGE_URI="${SYSTEM_URI%/}/Storage"
    STORAGE_JSON="$(redfish_get "$STORAGE_URI")"

    if echo "$STORAGE_JSON" | jq empty >/dev/null 2>&1; then
      STORAGE_MEMBERS="$(echo "$STORAGE_JSON" | jq -r '.Members[]?."@odata.id"')"

      for STORAGE_MEMBER_URI in $STORAGE_MEMBERS; do
        STORAGE_MEMBER_JSON="$(redfish_get "$STORAGE_MEMBER_URI")"

        if echo "$STORAGE_MEMBER_JSON" | jq empty >/dev/null 2>&1; then
          FOUND_DRIVES="$(echo "$STORAGE_MEMBER_JSON" | jq -r '.Drives[]?."@odata.id"')"
          if [[ -n "$FOUND_DRIVES" ]]; then
            DRIVE_URIS="${DRIVE_URIS}
${FOUND_DRIVES}"
          fi
        fi
      done
    fi
  done
fi

###############################################################################
# Method 2:
# Older HPE SmartStorage model:
#   /redfish/v1/Systems/<id>/SmartStorage/ArrayControllers
#   controller.Links.PhysicalDrives.@odata.id
#   physical drive collection.Members[].@odata.id
#
# HPE sample code also reads SSDEnduranceUtilizationPercentage from physical
# drive objects returned through SmartStorage physical drive links. :contentReference[oaicite:1]{index=1}
###############################################################################

if echo "$SYSTEMS_JSON" | jq empty >/dev/null 2>&1; then
  for SYSTEM_URI in $SYSTEM_URIS; do
    ARRAY_CONTROLLERS_URI="${SYSTEM_URI%/}/SmartStorage/ArrayControllers"
    ARRAY_CONTROLLERS_JSON="$(redfish_get "$ARRAY_CONTROLLERS_URI")"

    if echo "$ARRAY_CONTROLLERS_JSON" | jq empty >/dev/null 2>&1; then
      CONTROLLER_URIS="$(echo "$ARRAY_CONTROLLERS_JSON" | jq -r '.Members[]?."@odata.id"')"

      for CONTROLLER_URI in $CONTROLLER_URIS; do
        CONTROLLER_JSON="$(redfish_get "$CONTROLLER_URI")"

        if echo "$CONTROLLER_JSON" | jq empty >/dev/null 2>&1; then
          PD_COLLECTION_URI="$(echo "$CONTROLLER_JSON" | jq -r '.Links.PhysicalDrives."@odata.id" // .links.PhysicalDrives."@odata.id" // empty')"

          if [[ -n "$PD_COLLECTION_URI" ]]; then
            PD_COLLECTION_JSON="$(redfish_get "$PD_COLLECTION_URI")"

            if echo "$PD_COLLECTION_JSON" | jq empty >/dev/null 2>&1; then
              FOUND_DRIVES="$(echo "$PD_COLLECTION_JSON" | jq -r '.Members[]?."@odata.id"')"
              if [[ -n "$FOUND_DRIVES" ]]; then
                DRIVE_URIS="${DRIVE_URIS}
${FOUND_DRIVES}"
              fi
            fi
          fi
        fi
      done
    fi
  done
fi

# Remove blank lines and duplicates.
DRIVE_URIS="$(echo "$DRIVE_URIS" | sed '/^[[:space:]]*$/d' | sort -u)"

if [[ -z "$DRIVE_URIS" ]]; then
  echo "UNKNOWN - no Redfish drive URI found from Storage or SmartStorage API"
  exit 3
fi

STATUS_CODE=0
OK_MSGS=()
WARN_MSGS=()
CRIT_MSGS=()
UNKNOWN_MSGS=()
PERFDATA=()

while read -r DRIVE_URI; do
  [[ -z "$DRIVE_URI" ]] && continue

  DRIVE_JSON="$(redfish_get "$DRIVE_URI")"

  if ! echo "$DRIVE_JSON" | jq empty >/dev/null 2>&1; then
    UNKNOWN_MSGS+=("${DRIVE_URI}: invalid JSON or API error")
    [[ $STATUS_CODE -lt 3 ]] && STATUS_CODE=3
    continue
  fi

  # Some HPE models expose the property at the top level.
  # This fallback also searches recursively if the layout differs.
  ENDURANCE="$(echo "$DRIVE_JSON" | jq -r '
    .SSDEnduranceUtilizationPercentage //
    (.. | objects | .SSDEnduranceUtilizationPercentage? // empty) |
    select(. != null) |
    tostring
  ' 2>/dev/null | head -n 1)"

  NAME="$(echo "$DRIVE_JSON" | jq -r '.Name // .Id // "UnknownDrive"')"
  MODEL="$(echo "$DRIVE_JSON" | jq -r '.Model // "UnknownModel"')"
  SERIAL="$(echo "$DRIVE_JSON" | jq -r '.SerialNumber // .serialNumber // "UnknownSerial"')"
  MEDIA_TYPE="$(echo "$DRIVE_JSON" | jq -r '.MediaType // .mediaType // "UnknownMedia"')"
  HEALTH="$(echo "$DRIVE_JSON" | jq -r '.Status.Health // "UnknownHealth"')"
  STATE="$(echo "$DRIVE_JSON" | jq -r '.Status.State // "UnknownState"')"

  LABEL="${NAME}/${SERIAL}"

  if [[ -z "$ENDURANCE" || "$ENDURANCE" == "null" ]]; then
    UNKNOWN_MSGS+=("${LABEL}: no SSDEnduranceUtilizationPercentage found, media=${MEDIA_TYPE}, model=${MODEL}, health=${HEALTH}, state=${STATE}")
    continue
  fi

  if ! [[ "$ENDURANCE" =~ ^[0-9]+$ ]]; then
    UNKNOWN_MSGS+=("${LABEL}: invalid endurance value=${ENDURANCE}")
    continue
  fi

  SAFE_LABEL="$(echo "$SERIAL" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  PERFDATA+=("'ssd_endurance_used_${SAFE_LABEL}'=${ENDURANCE}%;${WARN};${CRIT};0;100")

  DETAIL="${LABEL}: endurance_used=${ENDURANCE}%, media=${MEDIA_TYPE}, model=${MODEL}, health=${HEALTH}, state=${STATE}, uri=${DRIVE_URI}"

  if (( ENDURANCE >= CRIT )); then
    CRIT_MSGS+=("$DETAIL")
    STATUS_CODE=2
  elif (( ENDURANCE >= WARN )); then
    WARN_MSGS+=("$DETAIL")
    if [[ $STATUS_CODE -lt 1 ]]; then
      STATUS_CODE=1
    fi
  else
    OK_MSGS+=("$DETAIL")
  fi

done <<< "$DRIVE_URIS"

if (( ${#CRIT_MSGS[@]} > 0 )); then
  SUMMARY="CRITICAL - ${#CRIT_MSGS[@]} disk(s) >= ${CRIT}% SSD endurance used"
elif (( ${#WARN_MSGS[@]} > 0 )); then
  SUMMARY="WARNING - ${#WARN_MSGS[@]} disk(s) >= ${WARN}% SSD endurance used"
elif (( ${#OK_MSGS[@]} > 0 )); then
  SUMMARY="OK - all detected SSD endurance values are below ${WARN}%"
else
  SUMMARY="UNKNOWN - no disk returned valid SSDEnduranceUtilizationPercentage"
  STATUS_CODE=3
fi

echo "${SUMMARY} | ${PERFDATA[*]}"

for msg in "${CRIT_MSGS[@]}"; do
  echo "CRITICAL: $msg"
done

for msg in "${WARN_MSGS[@]}"; do
  echo "WARNING : $msg"
done

for msg in "${OK_MSGS[@]}"; do
  echo "OK      : $msg"
done

for msg in "${UNKNOWN_MSGS[@]}"; do
  echo "UNKNOWN : $msg"
done

exit "$STATUS_CODE"
