#!/bin/bash
# ==============================================================================
# check_dell_disk_health_v1.sh
# Dell PowerEdge R740 / R740xd — iDRAC9 Redfish Disk Health & SSD Endurance Check
# ==============================================================================
#
# Purpose:
#   Query Dell iDRAC Redfish RESTful API and report physical disk health,
#   predictive failure state, capacity, media type, and SSD endurance.
#
# Target tested/expected platform family:
#   Dell PowerEdge R740 / R740xd with iDRAC9
#
# Primary Redfish paths used:
#   /redfish/v1/Systems/System.Embedded.1/
#   /redfish/v1/Managers/iDRAC.Embedded.1/
#   /redfish/v1/Systems/System.Embedded.1/Storage/
#     -> Members[*].@odata.id
#     -> each Storage resource Drives[*].@odata.id
#     -> each Drive resource
#
# SSD endurance logic:
#   Prefer standard Redfish field:
#     PredictedMediaLifeLeftPercent = % remaining, converted to % used
#   Fallback Dell OEM fields commonly seen in iDRAC storage inventory:
#     Oem.Dell.DellPhysicalDisk.RemainingRatedWriteEndurance = % remaining
#     Oem.Dell.DellPhysicalDisk.RatedWriteEnduranceUsed = % used
#     Oem.Dell.DellPhysicalDisk.SSDEnduranceUtilizationPercentage = % used
#
# Output compatibility:
#   CSV header intentionally matches check_hpe_disk_health.sh so the HTML wrapper
#   can parse either vendor with the same parser.
#
# USAGE:
#   chmod +x check_dell_disk_health_v1.sh
#   ./check_dell_disk_health_v1.sh -H <iDRAC_IP> -u <user> -p <pass> [OPTIONS]
#
# OPTIONS:
#   -o  Output format: table (default) | json | csv
#   -w  SSD wear WARN % used threshold (default 70)
#   -c  SSD wear CRIT % used threshold (default 90)
#   -t  HTTP timeout seconds (default 30)
#   -l  Log file path (tee output)
#   -d  Debug mode - dump raw JSON to stderr
#   -h  Help
#
# EXIT CODES:
#   0 = OK
#   2 = unhealthy drive, predictive failure, or SSD endurance warning/critical
#   3 = no drives found
#   4 = connection/authentication/API error
#   1 = usage or local dependency error
# ==============================================================================

# -- Colours -------------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

# -- Defaults ------------------------------------------------------------------
IDRAC_HOST=""; USERNAME=""; PASSWORD=""
OUTPUT_FORMAT="table"
WARN_THRESHOLD=70
CRIT_THRESHOLD=90
TIMEOUT=30
LOG_FILE=""
DEBUG=false
SYSTEM_PATH=""
MANAGER_PATH=""

usage() {
  cat <<USAGE_EOF
${BLD}Dell PowerEdge R740/R740xd iDRAC Redfish Disk Health Checker${NC}

Usage: $(basename "$0") -H <iDRAC_IP> -u <user> -p <pass> [OPTIONS]

  -H  iDRAC hostname or IP          (required)
  -u  iDRAC username                (required)
  -p  iDRAC password                (required)
  -o  Output: table | json | csv    (default: table)
  -w  SSD wear WARN threshold used% (default: ${WARN_THRESHOLD})
  -c  SSD wear CRIT threshold used% (default: ${CRIT_THRESHOLD})
  -t  HTTP timeout seconds          (default: ${TIMEOUT})
  -l  Append output to log file
  -d  Debug - dump raw JSON to stderr
  -h  Show this help

Examples:
  $(basename "$0") -H 192.168.1.20 -u root -p calvin
  $(basename "$0") -H 192.168.1.20 -u root -p calvin -o csv
  $(basename "$0") -H 192.168.1.20 -u root -p calvin -d 2>debug.log
USAGE_EOF
  exit 0
}

while getopts "H:u:p:o:w:c:t:l:dh" opt; do
  case "$opt" in
    H) IDRAC_HOST="$OPTARG" ;;
    u) USERNAME="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;
    o) OUTPUT_FORMAT="$OPTARG" ;;
    w) WARN_THRESHOLD="$OPTARG" ;;
    c) CRIT_THRESHOLD="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    d) DEBUG=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [[ -z "$IDRAC_HOST" || -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo -e "${RED}[ERROR]${NC} -H, -u, -p are all required. Use -h for help."
  exit 1
fi

case "$OUTPUT_FORMAT" in
  table|json|csv) ;;
  *) echo -e "${RED}[ERROR]${NC} Unknown output format: $OUTPUT_FORMAT"; exit 1 ;;
esac

for cmd in curl jq bc sed grep date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Missing command: ${BLD}${cmd}${NC}"
    echo "  Debian/Ubuntu : sudo apt install curl jq bc sed grep coreutils"
    echo "  RHEL/CentOS   : sudo yum install curl jq bc sed grep coreutils"
    exit 1
  fi
done

[[ -n "$LOG_FILE" ]] && exec > >(tee -a "$LOG_FILE") 2>&1

BASE="https://${IDRAC_HOST}/redfish/v1"

# ------------------------------------------------------------------------------
# HTTP GET helper. Returns response body on success, empty string on error.
# ------------------------------------------------------------------------------
idrac_get() {
  local path="$1"
  local url combined code body

  if [[ "$path" =~ ^https?:// ]]; then
    url="$path"
  elif [[ "$path" =~ ^/redfish/v1 ]]; then
    url="https://${IDRAC_HOST}${path}"
  else
    [[ "$path" != /* ]] && path="/$path"
    url="${BASE}${path}"
  fi

  combined=$(curl --silent --insecure \
    --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    --user "${USERNAME}:${PASSWORD}" \
    --header "Accept: application/json" \
    --write-out '\n__CODE__%{http_code}' \
    "$url" 2>/dev/null)

  code=$(printf '%s\n' "$combined" | grep -o '__CODE__[0-9]*' | sed 's/__CODE__//')
  body=$(printf '%s\n' "$combined" | sed '/__CODE__/d')

  if [[ "$DEBUG" == true ]]; then
    printf "${CYN}[DEBUG] GET %s -> HTTP %s${NC}\n%s\n\n" "$url" "${code:-NO_CODE}" "$body" >&2
  fi

  if [[ -z "$code" ]]; then
    echo -e "${RED}[ERROR]${NC} No response from ${url}" >&2
    echo ""
    return 1
  fi

  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    [[ "$code" != "404" ]] && echo -e "${RED}[ERROR]${NC} HTTP ${code} from ${url}" >&2
    echo ""
    return 1
  fi

  echo "$body"
}

# Convert an absolute @odata.id to relative path accepted by idrac_get.
normalize_path() {
  local p="$1"
  p="${p#https://${IDRAC_HOST}}"
  p="${p#https://${IDRAC_HOST}/redfish/v1}"
  if [[ "$p" =~ ^/redfish/v1 ]]; then
    echo "$p"
  else
    p="${p#/redfish/v1}"
    [[ "$p" != /* ]] && p="/$p"
    echo "$p"
  fi
}

json_string() {
  printf '%s' "$1" | jq -Rs .
}

clean_percent() {
  local v="$1"
  v="${v%%%}"
  v="${v//[^0-9.]/}"
  [[ -z "$v" ]] && echo "" || echo "$v"
}

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

color_health() {
  case "$1" in
    OK) printf "${GRN}%-9s${NC}" "$1" ;;
    Warning|NonCritical) printf "${YLW}%-9s${NC}" "$1" ;;
    Critical|Failed|CriticalFailure) printf "${RED}%-9s${NC}" "$1" ;;
    *) printf "${CYN}%-9s${NC}" "${1:-N/A}" ;;
  esac
}

color_ssd() {
  local v="$1"
  [[ "$v" == "N/A" || -z "$v" ]] && { printf "%-9s" "N/A"; return; }
  if (( $(echo "$v >= $CRIT_THRESHOLD" | bc -l) )); then
    printf "${RED}%-9s${NC}" "${v}%"
  elif (( $(echo "$v >= $WARN_THRESHOLD" | bc -l) )); then
    printf "${YLW}%-9s${NC}" "${v}%"
  else
    printf "${GRN}%-9s${NC}" "${v}%"
  fi
}

# ------------------------------------------------------------------------------
# Discover the Dell system and manager paths.
# ------------------------------------------------------------------------------
discover_paths() {
  local systems managers s m

  systems=$(idrac_get "/Systems/") || return 1
  SYSTEM_PATH=$(printf '%s' "$systems" | jq -r '
    [.Members[]."@odata.id" // empty]
    | (map(select(test("System\\.Embedded\\.1"))) | .[0]) // .[0] // empty')
  SYSTEM_PATH=$(normalize_path "$SYSTEM_PATH")

  managers=$(idrac_get "/Managers/") || true
  if [[ -n "$managers" ]]; then
    MANAGER_PATH=$(printf '%s' "$managers" | jq -r '
      [.Members[]."@odata.id" // empty]
      | (map(select(test("iDRAC\\.Embedded\\.1"))) | .[0]) // .[0] // empty')
    [[ -n "$MANAGER_PATH" ]] && MANAGER_PATH=$(normalize_path "$MANAGER_PATH")
  fi

  [[ -n "$SYSTEM_PATH" ]]
}

# ------------------------------------------------------------------------------
# Row accumulator. CSV columns match HPE checker:
# Controller,Location,Model,SerialNumber,MediaType,Health,State,
# SSDEnduranceUsed%,CapacityGB,FirmwareVersion,FailurePredicted
# ------------------------------------------------------------------------------
declare -a ROWS=()
TOTAL=0
UNHEALTHY=0
SSD_ISSUES=0

add_drive() {
  local ctrl="$1" loc="$2" model="$3" serial="$4" media="$5"
  local health="$6" state="$7" ssd="$8" cap="$9" fw="${10}" fail="${11}"

  [[ -z "$ctrl" ]] && ctrl="N/A"
  [[ -z "$loc" ]] && loc="N/A"
  [[ -z "$model" ]] && model="N/A"
  [[ -z "$serial" ]] && serial="N/A"
  [[ -z "$media" ]] && media="N/A"
  [[ -z "$health" ]] && health="N/A"
  [[ -z "$state" ]] && state="N/A"
  [[ -z "$ssd" ]] && ssd="N/A"
  [[ -z "$cap" ]] && cap="N/A"
  [[ -z "$fw" ]] && fw="N/A"
  [[ -z "$fail" ]] && fail="false"

  ROWS+=("${ctrl}|${loc}|${model}|${serial}|${media}|${health}|${state}|${ssd}|${cap}|${fw}|${fail}")
  (( TOTAL++ )) || true

  if [[ "$health" != "OK" && "$health" != "N/A" && -n "$health" ]]; then
    (( UNHEALTHY++ )) || true
  fi
  if [[ "$fail" == "true" || "$fail" == "Yes" || "$fail" == "PredictiveFailure" ]]; then
    (( UNHEALTHY++ )) || true
  fi
  if [[ "$ssd" != "N/A" && -n "$ssd" ]]; then
    if (( $(echo "$ssd >= $WARN_THRESHOLD" | bc -l) )); then
      (( SSD_ISSUES++ )) || true
    fi
  fi

  if [[ "$OUTPUT_FORMAT" == "table" ]]; then
    local fail_tag=""
    [[ "$fail" == "true" || "$fail" == "Yes" || "$fail" == "PredictiveFailure" ]] && fail_tag="  ${RED}FAILURE PREDICTED${NC}"
    printf "  %-12s %-26s %-16s %-8s " "${loc:0:11}" "${model:0:25}" "${serial:0:15}" "${media:0:7}"
    color_health "$health"
    printf " %-12s " "$state"
    color_ssd "$ssd"
    printf " %-8s%b\n" "$cap" "$fail_tag"
  fi
}

# ------------------------------------------------------------------------------
# Extract drive fields from a Drive JSON object.
# ------------------------------------------------------------------------------
parse_drive_and_add() {
  local ctrl_name="$1" dj="$2"
  local loc model serial media health state cap fw fail ssd life_left used oem_rrwe oem_predictive raid_status

  loc=$(printf '%s' "$dj" | jq -r '
    .PhysicalLocation.PartLocation.ServiceLabel //
    .Location.PartLocation.ServiceLabel //
    .Oem.Dell.DellPhysicalDisk.Slot //
    .Oem.Dell.DellPhysicalDisk.SlotNumber //
    .Oem.Dell.DellPhysicalDisk.DeviceDescription //
    .Id // "N/A"' 2>/dev/null)

  model=$(printf '%s' "$dj" | jq -r '.Model // .Name // .Oem.Dell.DellPhysicalDisk.Model // "N/A"')
  serial=$(printf '%s' "$dj" | jq -r '.SerialNumber // .Oem.Dell.DellPhysicalDisk.SerialNumber // "N/A"')
  media=$(printf '%s' "$dj" | jq -r '.MediaType // .Oem.Dell.DellPhysicalDisk.MediaType // .Protocol // "N/A"')
  health=$(printf '%s' "$dj" | jq -r '.Status.Health // .Oem.Dell.DellPhysicalDisk.PrimaryStatus // "N/A"')
  state=$(printf '%s' "$dj" | jq -r '.Status.State // .Oem.Dell.DellPhysicalDisk.RaidStatus // .Oem.Dell.DellPhysicalDisk.DriveStatus // "N/A"')
  fw=$(printf '%s' "$dj" | jq -r '.Revision // .FirmwareVersion // .Oem.Dell.DellPhysicalDisk.Revision // "N/A"')
  cap=$(printf '%s' "$dj" | jq -r '
    if .CapacityBytes then ((.CapacityBytes/1073741824)|floor|tostring)
    elif .CapacityGB then (.CapacityGB|tostring)
    elif .CapacityMiB then ((.CapacityMiB/1024)|floor|tostring)
    elif .Oem.Dell.DellPhysicalDisk.SizeInBytes then ((.Oem.Dell.DellPhysicalDisk.SizeInBytes/1073741824)|floor|tostring)
    else "N/A" end')

  fail=$(printf '%s' "$dj" | jq -r '
    .FailurePredicted //
    .Oem.Dell.DellPhysicalDisk.PredictiveFailureState //
    .Oem.Dell.DellPhysicalDisk.PredictiveFailure //
    false')

  # Normalize Dell strings for predictive failure.
  case "$fail" in
    true|True|TRUE|Yes|YES|PredictiveFailure|FailurePredicted) fail="true" ;;
    *) fail="false" ;;
  esac

  # SSD endurance extraction. Convert all possible "remaining" fields to used%.
  ssd="N/A"
  life_left=$(printf '%s' "$dj" | jq -r '.PredictedMediaLifeLeftPercent // empty')
  life_left=$(clean_percent "$life_left")
  if is_number "$life_left"; then
    ssd=$(echo "100 - $life_left" | bc)
  else
    oem_rrwe=$(printf '%s' "$dj" | jq -r '
      .Oem.Dell.DellPhysicalDisk.RemainingRatedWriteEndurance //
      .Oem.Dell.DellPhysicalDisk.RemainingRatedWriteEndurancePercent //
      .Oem.Dell.DellPhysicalDisk.RemainingRatedWriteEndurancePercentage //
      empty')
    oem_rrwe=$(clean_percent "$oem_rrwe")
    if is_number "$oem_rrwe"; then
      ssd=$(echo "100 - $oem_rrwe" | bc)
    else
      used=$(printf '%s' "$dj" | jq -r '
        .Oem.Dell.DellPhysicalDisk.RatedWriteEnduranceUsed //
        .Oem.Dell.DellPhysicalDisk.SSDEnduranceUtilizationPercentage //
        .Oem.Dell.DellPhysicalDisk.SSDEnduranceUsedPercent //
        empty')
      used=$(clean_percent "$used")
      if is_number "$used"; then
        ssd="$used"
      fi
    fi
  fi

  # Only display endurance for likely SSD/media types. If Dell reports endurance
  # on an SSD but media is not explicit, keep it. Otherwise show N/A for HDD.
  if [[ "$media" =~ HDD|Rotational|HardDisk|Hard.Disk ]]; then
    ssd="N/A"
  fi

  add_drive "$ctrl_name" "$loc" "$model" "$serial" "$media" "$health" "$state" "$ssd" "$cap" "$fw" "$fail"
}

collect_storage() {
  local storage_col storage_uris stor_uri stor_path stor_json ctrl_name ctrl_health ctrl_fw drive_uris drive_uri drive_path dj d_count any=false
  local storage_path="${SYSTEM_PATH%/}/Storage/"

  echo -e "${BLD}[PATH]${NC} Dell iDRAC Storage — ${storage_path}"
  storage_col=$(idrac_get "$storage_path")
  [[ -z "$storage_col" ]] && { echo -e "  ${RED}[ERROR]${NC} Cannot access storage collection."; return 1; }

  storage_uris=$(printf '%s' "$storage_col" | jq -r '.Members[]."@odata.id" // empty')
  [[ -z "$storage_uris" ]] && { echo -e "  ${YLW}No storage controllers/subsystems found.${NC}"; return 1; }

  local stor_count
  stor_count=$(printf '%s' "$storage_col" | jq -r '."Members@odata.count" // (.Members | length)')
  echo -e "  Found ${BLD}${stor_count}${NC} storage subsystem(s).\n"

  while IFS= read -r stor_uri; do
    stor_path=$(normalize_path "$stor_uri")
    stor_json=$(idrac_get "$stor_path")
    [[ -z "$stor_json" ]] && continue

    ctrl_name=$(printf '%s' "$stor_json" | jq -r '
      .StorageControllers[0].Name //
      .StorageControllers[0].Model //
      .Name // .Id // "Unknown"')
    ctrl_health=$(printf '%s' "$stor_json" | jq -r '.Status.Health // "N/A"')
    ctrl_fw=$(printf '%s' "$stor_json" | jq -r '.StorageControllers[0].FirmwareVersion // .StorageControllers[0].FirmwarePackageVersion // "N/A"')

    echo -e "  ${BLD}Storage     :${NC} ${ctrl_name}  (ID: $(basename "$stor_path"))"
    echo -e "  ${BLD}FW          :${NC} ${ctrl_fw}"
    printf  "  ${BLD}Health      :${NC} "; color_health "$ctrl_health"; echo -e "\n"

    drive_uris=$(printf '%s' "$stor_json" | jq -r '.Drives[]."@odata.id" // empty' 2>/dev/null)

    # Fallback for some iDRAC firmware: drives may be exposed as a Drives collection link.
    if [[ -z "$drive_uris" ]]; then
      local drives_collection
      drives_collection=$(printf '%s' "$stor_json" | jq -r '.Links.Drives."@odata.id" // .Drives."@odata.id" // empty' 2>/dev/null)
      if [[ -n "$drives_collection" ]]; then
        local dc_json
        dc_json=$(idrac_get "$(normalize_path "$drives_collection")")
        drive_uris=$(printf '%s' "$dc_json" | jq -r '.Members[]."@odata.id" // empty' 2>/dev/null)
      fi
    fi

    [[ -z "$drive_uris" ]] && { echo -e "  ${YLW}No physical drives listed in this storage subsystem.${NC}\n"; continue; }

    d_count=$(printf '%s\n' "$drive_uris" | sed '/^$/d' | wc -l | tr -d ' ')
    echo -e "  Found ${BLD}${d_count}${NC} drive(s)."

    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
      printf "  ${BLD}%-12s %-26s %-16s %-8s %-9s %-12s %-9s %-8s${NC}\n" \
        "Bay" "Model" "Serial" "Type" "Health" "State" "SSDWear%" "Cap(GB)"
      printf "  %s\n" "$(printf -- '-%.0s' {1..104})"
    fi

    while IFS= read -r drive_uri; do
      [[ -z "$drive_uri" ]] && continue
      drive_path=$(normalize_path "$drive_uri")
      dj=$(idrac_get "$drive_path")
      [[ -z "$dj" ]] && continue
      parse_drive_and_add "$ctrl_name" "$dj"
      any=true
    done <<< "$drive_uris"
    echo ""
  done <<< "$storage_uris"

  [[ "$any" == true ]]
}

render_json() {
  echo "["
  local idx=0 sep row ctrl loc model serial media health state ssd cap fw fail
  for row in "${ROWS[@]}"; do
    IFS='|' read -r ctrl loc model serial media health state ssd cap fw fail <<< "$row"
    (( idx++ )) || true
    sep=$( [[ $idx -lt ${#ROWS[@]} ]] && echo "," || echo "" )
    printf '  {\n'
    printf '    "controller": %s,\n' "$(json_string "$ctrl")"
    printf '    "location": %s,\n' "$(json_string "$loc")"
    printf '    "model": %s,\n' "$(json_string "$model")"
    printf '    "serialNumber": %s,\n' "$(json_string "$serial")"
    printf '    "mediaType": %s,\n' "$(json_string "$media")"
    printf '    "health": %s,\n' "$(json_string "$health")"
    printf '    "state": %s,\n' "$(json_string "$state")"
    printf '    "SSDEnduranceUsedPercent": %s,\n' "$(json_string "$ssd")"
    printf '    "capacityGB": %s,\n' "$(json_string "$cap")"
    printf '    "firmwareVersion": %s,\n' "$(json_string "$fw")"
    printf '    "failurePredicted": %s\n' "$(json_string "$fail")"
    printf '  }%s\n' "$sep"
  done
  echo "]"
}

render_csv() {
  echo "Controller,Location,Model,SerialNumber,MediaType,Health,State,SSDEnduranceUsed%,CapacityGB,FirmwareVersion,FailurePredicted"
  local row ctrl loc model serial media health state ssd cap fw fail
  for row in "${ROWS[@]}"; do
    IFS='|' read -r ctrl loc model serial media health state ssd cap fw fail <<< "$row"
    # Keep CSV simple to match the existing HTML wrapper. Dell fields normally do
    # not contain commas; replace any rare comma with space to avoid parser split.
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${ctrl//,/ }" "${loc//,/ }" "${model//,/ }" "${serial//,/ }" "${media//,/ }" \
      "${health//,/ }" "${state//,/ }" "${ssd//,/ }" "${cap//,/ }" "${fw//,/ }" "${fail//,/ }"
  done
}

render_summary() {
  echo -e "${BLD}${CYN}══════════════════════════ SUMMARY ══════════════════════════${NC}"
  printf "  %-24s %d\n" "Total Drives:" "$TOTAL"
  printf "  %-24s " "Unhealthy / Failed:"
  [[ $UNHEALTHY -gt 0 ]] && echo -e "${RED}${UNHEALTHY}${NC}" || echo -e "${GRN}${UNHEALTHY}${NC}"
  printf "  %-24s " "SSD Wear Alerts:"
  [[ $SSD_ISSUES -gt 0 ]] && echo -e "${YLW}${SSD_ISSUES}${NC}" || echo -e "${GRN}${SSD_ISSUES}${NC}"
  echo ""
}

# -- MAIN ----------------------------------------------------------------------
echo ""
echo -e "${BLD}${CYN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}${CYN}║ Dell PowerEdge R740/R740xd — Disk Health & SSD Endurance    ║${NC}"
echo -e "${BLD}${CYN}╚═══════════════════════════════════════════════════════════════╝${NC}"
printf "  %-16s %s\n" "Target:" "$IDRAC_HOST"
printf "  %-16s %s\n" "User:" "$USERNAME"
printf "  %-16s %s\n" "Time:" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-16s warn>=%s%%  crit>=%s%%\n" "SSD Thresholds:" "$WARN_THRESHOLD" "$CRIT_THRESHOLD"
[[ "$DEBUG" == true ]] && echo -e "  ${YLW}Debug ON - raw JSON to stderr${NC}"
echo ""

echo -e "${BLD}[Step 1]${NC} Discovering iDRAC Redfish resources..."
if ! discover_paths; then
  echo -e "${RED}[ERROR]${NC} Cannot discover Redfish Systems collection. Check IP, credentials, TLS, and network."
  exit 4
fi

SYSTEM_JSON=$(idrac_get "$SYSTEM_PATH")
SYSTEM_MODEL=$(printf '%s' "$SYSTEM_JSON" | jq -r '.Model // .Name // "PowerEdge"')
SYSTEM_SERIAL=$(printf '%s' "$SYSTEM_JSON" | jq -r '.SerialNumber // "N/A"')

IDRAC_MODEL="iDRAC"
IDRAC_FW="N/A"
if [[ -n "$MANAGER_PATH" ]]; then
  MGR_JSON=$(idrac_get "$MANAGER_PATH")
  if [[ -n "$MGR_JSON" ]]; then
    IDRAC_MODEL=$(printf '%s' "$MGR_JSON" | jq -r '.Model // .Name // "iDRAC"')
    IDRAC_FW=$(printf '%s' "$MGR_JSON" | jq -r '.FirmwareVersion // "N/A"')
  fi
fi

echo -e "  System : ${BLD}${SYSTEM_MODEL}${NC}  Serial: ${BLD}${SYSTEM_SERIAL}${NC}"
echo -e "  Manager: ${BLD}${IDRAC_MODEL}${NC}  Firmware: ${BLD}${IDRAC_FW}${NC}"
echo -e "  System path: ${BLD}${SYSTEM_PATH}${NC}"
echo ""

echo -e "${BLD}[Step 2]${NC} Collecting drive information...\n"
FOUND_DRIVES=false
collect_storage && FOUND_DRIVES=true

case "$OUTPUT_FORMAT" in
  table) render_summary ;;
  json) render_json ;;
  csv) render_csv ;;
esac

if [[ "$FOUND_DRIVES" == false || "$TOTAL" -eq 0 ]]; then
  echo -e "${YLW}[WARN]${NC} No drives found."
  echo -e "  Tip: re-run with ${BLD}-d${NC} to inspect raw Redfish responses."
  exit 3
elif [[ $UNHEALTHY -gt 0 || $SSD_ISSUES -gt 0 ]]; then
  echo -e "${RED}[ACTION REQUIRED]${NC} One or more drives need attention - review output above."
  exit 2
fi

echo -e "${GRN}[OK]${NC} All ${TOTAL} drive(s) healthy. No SSD endurance alerts."
exit 0
