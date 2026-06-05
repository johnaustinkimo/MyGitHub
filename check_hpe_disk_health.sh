#!/bin/bash
# ==============================================================================
# check_hpe_disk_health.sh
# Universal HPE iLO 4 / iLO 5 / iLO 6 — Disk Drive Health & SSD Endurance
# ==============================================================================
#
# HOW EACH iLO VERSION EXPOSES DRIVES:
#
#  iLO 4 (Gen9)  — HPE OEM SmartStorage only
#    /redfish/v1/Systems/1/SmartStorage/ArrayControllers/
#      └─ [ctrl]/ → Links.PhysicalDrives["@odata.id"]
#           └─ DiskDrives collection → Members[*]["@odata.id"]
#                └─ [drive]/ → Status.Health, SSDEnduranceUtilizationPercentage …
#
#  iLO 5 (Gen10) — BOTH paths may exist
#    PATH-A (OEM SmartStorage, same as iLO 4 above)          ← preferred
#    PATH-B (DMTF Storage, added in later iLO 5 firmware)
#      /redfish/v1/Systems/1/Storage/
#        └─ [storageId]/ → Drives[*]["@odata.id"]
#             └─ [drive]/ → same fields
#
#  iLO 6 (Gen11) — DMTF Storage ONLY (OEM SmartStorage removed)
#    /redfish/v1/Systems/1/Storage/
#      └─ [storageId]/ → Drives[*]["@odata.id"]
#           └─ [drive]/ → Status.Health, PredictedMediaLifeLeftPercent …
#
#  SSD endurance field names:
#    OEM path  → SSDEnduranceUtilizationPercentage  (% used, 0–100)
#    DMTF path → PredictedMediaLifeLeftPercent       (% remaining, 100→0)
#               (converted to "% used" for uniform display)
#
# USAGE:
#   chmod +x check_hpe_disk_health.sh
#   ./check_hpe_disk_health.sh -H <iLO_IP> -u <user> -p <pass> [OPTIONS]
#
# OPTIONS:
#   -o  Output format: table (default) | json | csv
#   -w  SSD wear WARN % (default 70)
#   -c  SSD wear CRIT % (default 90)
#   -t  HTTP timeout in seconds (default 30)
#   -l  Log file path (tee output)
#   -d  Debug mode — dump raw JSON to stderr
#   -h  Help
#
# EXIT CODES:  0=OK  2=issue found  3=no drives  4=connection error
# ==============================================================================

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[1;33m'
CYN='\033[0;36m' WHT='\033[1;37m' BLD='\033[1m' NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
ILO_HOST="" USERNAME="" PASSWORD=""
OUTPUT_FORMAT="table"
WARN_THRESHOLD=70
CRIT_THRESHOLD=90
TIMEOUT=30
LOG_FILE=""
DEBUG=false

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BLD}HPE iLO 4/5/6 Universal Disk Health Checker${NC}

Usage: $(basename "$0") -H <iLO_IP> -u <user> -p <pass> [OPTIONS]

  -H  iLO hostname or IP  (required)
  -u  iLO username         (required)
  -p  iLO password         (required)
  -o  Output: table | json | csv  (default: table)
  -w  SSD wear WARN threshold  (default: ${WARN_THRESHOLD}%)
  -c  SSD wear CRIT threshold  (default: ${CRIT_THRESHOLD}%)
  -t  HTTP timeout seconds     (default: ${TIMEOUT})
  -l  Append output to log file
  -d  Debug — dump raw JSON to stderr
  -h  Show this help

Examples:
  $(basename "$0") -H 192.168.1.10 -u Administrator -p Admin123
  $(basename "$0") -H 192.168.1.10 -u Administrator -p Admin123 -o csv -l /var/log/disk.log
  $(basename "$0") -H 192.168.1.10 -u Administrator -p Admin123 -d 2>debug.log
EOF
  exit 0
}

while getopts "H:u:p:o:w:c:t:l:dh" opt; do
  case $opt in
    H) ILO_HOST="$OPTARG"       ;; u) USERNAME="$OPTARG"        ;;
    p) PASSWORD="$OPTARG"       ;; o) OUTPUT_FORMAT="$OPTARG"   ;;
    w) WARN_THRESHOLD="$OPTARG" ;; c) CRIT_THRESHOLD="$OPTARG"  ;;
    t) TIMEOUT="$OPTARG"        ;; l) LOG_FILE="$OPTARG"        ;;
    d) DEBUG=true               ;; h) usage                      ;;
    *) usage ;;
  esac
done

[[ -z "$ILO_HOST" || -z "$USERNAME" || -z "$PASSWORD" ]] && {
  echo -e "${RED}[ERROR]${NC} -H, -u, -p are all required. Use -h for help."; exit 1; }

for cmd in curl jq bc; do
  command -v "$cmd" &>/dev/null || {
    echo -e "${RED}[ERROR]${NC} Missing: ${BLD}${cmd}${NC}. Install with:"
    echo "  Debian/Ubuntu : sudo apt install ${cmd}"
    echo "  RHEL/CentOS   : sudo yum install ${cmd}"
    exit 1; }
done

[[ -n "$LOG_FILE" ]] && exec > >(tee -a "$LOG_FILE") 2>&1

BASE="https://${ILO_HOST}/redfish/v1"

# ==============================================================================
# Core HTTP helper
# Returns response body; empty string on error.
# ==============================================================================
ilo_get() {
  local path="$1"
  local url="${BASE}${path}"
  local combined body code

  combined=$(curl --silent --insecure \
    --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    --user "${USERNAME}:${PASSWORD}" \
    --header "Accept: application/json" \
    --write-out '\n__CODE__%{http_code}' \
    "$url" 2>/dev/null)

  code=$(echo "$combined" | grep -o '__CODE__[0-9]*' | sed 's/__CODE__//')
  body=$(echo "$combined" | sed '/__CODE__/d')

  [[ "$DEBUG" == true ]] && \
    printf "${CYN}[DEBUG] GET %s  → HTTP %s${NC}\n%s\n\n" "$url" "$code" "$body" >&2

  if [[ -z "$code" ]]; then
    echo -e "${RED}[ERROR]${NC} No response from ${url} (timeout or unreachable)" >&2
    echo ""; return 1
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    [[ "$code" != "404" ]] && \
      echo -e "${RED}[ERROR]${NC} HTTP ${code} from ${url}" >&2
    echo ""; return 1
  fi
  echo "$body"
}

# ==============================================================================
# Detect iLO generation by reading /redfish/v1/Managers/1/
# Returns: 4 | 5 | 6 | unknown
# ==============================================================================
detect_ilo_version() {
  local mgr_json
  mgr_json=$(ilo_get "/Managers/1/")
  if [[ -z "$mgr_json" ]]; then echo "unknown"; return; fi

  local fw_string
  fw_string=$(echo "$mgr_json" | jq -r '
    .FirmwareVersion //
    .Oem.Hp.Firmware.Current.VersionString //
    .Oem.Hpe.Firmware.Current.VersionString //
    ""')

  if echo "$fw_string" | grep -qi "iLO 6"; then echo "6"
  elif echo "$fw_string" | grep -qi "iLO 5"; then echo "5"
  elif echo "$fw_string" | grep -qi "iLO 4"; then echo "4"
  else
    # Fallback: check if OEM SmartStorage path exists
    local ss_test
    ss_test=$(ilo_get "/Systems/1/SmartStorage/ArrayControllers/")
    if [[ -n "$ss_test" ]]; then echo "4or5"
    else echo "6"; fi
  fi
}

# ==============================================================================
# Colour helpers
# ==============================================================================
color_health() {
  case "$1" in
    OK)                printf "${GRN}%-9s${NC}" "$1" ;;
    Warning)           printf "${YLW}%-9s${NC}" "$1" ;;
    Critical|Failed)   printf "${RED}%-9s${NC}" "$1" ;;
    *)                 printf "${CYN}%-9s${NC}" "${1:-N/A}" ;;
  esac
}

color_ssd() {
  local v="$1"
  [[ "$v" == "N/A" || -z "$v" ]] && { printf "%-9s" "N/A"; return; }
  if   (( $(echo "$v >= $CRIT_THRESHOLD" | bc -l) )); then printf "${RED}%-9s${NC}" "${v}%"
  elif (( $(echo "$v >= $WARN_THRESHOLD" | bc -l) )); then printf "${YLW}%-9s${NC}" "${v}%"
  else printf "${GRN}%-9s${NC}" "${v}%"
  fi
}

# ==============================================================================
# Parse FirmwareVersion regardless of whether it is a plain string or the
# iLO 4/5 nested object {"Current":{"VersionString":"x.xx"}}
# ==============================================================================
parse_fw() {
  echo "$1" | jq -r '
    if type == "string" then .
    elif .Current.VersionString then .Current.VersionString
    else "N/A"
    end' 2>/dev/null || echo "N/A"
}

# ==============================================================================
# Shared per-drive record accumulator
# Usage: add_drive CTRL_NAME LOCATION MODEL SERIAL MEDIA HEALTH STATE SSD_PCT CAP FW FAIL
# ==============================================================================
declare -a ROWS=()
TOTAL=0; UNHEALTHY=0; SSD_ISSUES=0

add_drive() {
  local ctrl="$1" loc="$2" model="$3" serial="$4" media="$5"
  local health="$6" state="$7" ssd="$8" cap="$9" fw="${10}" fail="${11}"

  ROWS+=("${ctrl}|${loc}|${model}|${serial}|${media}|${health}|${state}|${ssd}|${cap}|${fw}|${fail}")
  (( TOTAL++ )) || true
  [[ "$health" != "OK" && "$health" != "N/A" && -n "$health" ]] && (( UNHEALTHY++ )) || true
  [[ "$fail" == "true" ]] && (( UNHEALTHY++ )) || true
  if [[ "$ssd" != "N/A" && -n "$ssd" ]]; then
    (( $(echo "$ssd >= $WARN_THRESHOLD" | bc -l) )) && (( SSD_ISSUES++ )) || true
  fi

  if [[ "$OUTPUT_FORMAT" == "table" ]]; then
    local fail_tag=""
    [[ "$fail" == "true" ]] && fail_tag="  ${RED}⚠ FAILURE PREDICTED${NC}"
    printf "  %-9s %-24s %-14s %-6s " \
      "${loc:0:8}" "${model:0:23}" "${serial:0:13}" "${media:0:5}"
    color_health "$health"
    printf " %-11s " "$state"
    color_ssd "$ssd"
    printf " %-7s%b\n" "$cap" "$fail_tag"
  fi
}

# ==============================================================================
# PATH A — OEM SmartStorage (iLO 4 / iLO 5)
#   /redfish/v1/Systems/1/SmartStorage/ArrayControllers/
#     → ctrl → Links.PhysicalDrives (or Links.DiskDrives)
#         → DiskDrives collection → individual drives
# ==============================================================================
collect_oem_smartstorage() {
  echo -e "${BLD}[PATH-A]${NC} OEM SmartStorage — /Systems/1/SmartStorage/ArrayControllers/"

  local ctrl_col ctrl_uris ctrl_count
  ctrl_col=$(ilo_get "/Systems/1/SmartStorage/ArrayControllers/")
  [[ -z "$ctrl_col" ]] && { echo -e "  ${YLW}Not available on this iLO.${NC}"; return 1; }

  ctrl_uris=$(echo "$ctrl_col" | jq -r '.Members[]."@odata.id" // empty')
  ctrl_count=$(echo "$ctrl_col" | jq -r '."Members@odata.count" // (.Members | length)' 2>/dev/null)
  [[ -z "$ctrl_uris" ]] && { echo -e "  ${YLW}No array controllers found.${NC}"; return 1; }

  echo -e "  Found ${BLD}${ctrl_count}${NC} controller(s).\n"

  local any_drives=false

  while IFS= read -r ctrl_uri; do
    # Normalise to relative path
    local ctrl_path="${ctrl_uri#https://${ILO_HOST}/redfish/v1}"
    ctrl_path="${ctrl_path#/redfish/v1}"
    [[ "$ctrl_path" != /* ]] && ctrl_path="/${ctrl_path}"

    local ctrl_json
    ctrl_json=$(ilo_get "$ctrl_path")
    [[ -z "$ctrl_json" ]] && continue

    local ctrl_name ctrl_health ctrl_sn ctrl_loc ctrl_fw
    ctrl_name=$(echo "$ctrl_json"   | jq -r '.Model // .Name // "Unknown"')
    ctrl_health=$(echo "$ctrl_json" | jq -r '.Status.Health // "N/A"')
    ctrl_sn=$(echo "$ctrl_json"     | jq -r '.SerialNumber // "N/A"')
    ctrl_loc=$(echo "$ctrl_json"    | jq -r '.Location // "N/A"')
    ctrl_fw=$(parse_fw "$(echo "$ctrl_json" | jq -c '.FirmwareVersion // "N/A"')")

    echo -e "  ${BLD}Controller :${NC} ${ctrl_name}"
    echo -e "  ${BLD}Serial     :${NC} ${ctrl_sn}   ${BLD}FW:${NC} ${ctrl_fw}   ${BLD}Slot:${NC} ${ctrl_loc}"
    printf  "  ${BLD}Health     :${NC} "; color_health "$ctrl_health"; echo -e "\n"

    # Resolve DiskDrives link — check several possible key names
    local drives_path
    drives_path=$(echo "$ctrl_json" | jq -r '
      .Links.PhysicalDrives["@odata.id"] //
      .Links.PhysicalDrives.href         //
      .Links.DiskDrives["@odata.id"]     //
      .Links.DiskDrives.href             //
      empty' 2>/dev/null)
    drives_path="${drives_path#https://${ILO_HOST}/redfish/v1}"
    drives_path="${drives_path#/redfish/v1}"
    [[ "$drives_path" != /* && -n "$drives_path" ]] && drives_path="/${drives_path}"

    if [[ -z "$drives_path" ]]; then
      # Fallback: conventional sub-path
      drives_path="${ctrl_path%/}/DiskDrives/"
      echo -e "  ${YLW}[WARN]${NC} No DiskDrives link in controller JSON; trying ${drives_path}"
    fi

    local drives_col drive_uris
    drives_col=$(ilo_get "$drives_path")
    [[ -z "$drives_col" ]] && { echo -e "  ${RED}[ERROR]${NC} Cannot GET ${drives_path}\n"; continue; }

    drive_uris=$(echo "$drives_col" | jq -r '.Members[]."@odata.id" // empty')
    [[ -z "$drive_uris" ]] && { echo -e "  ${YLW}No drives in collection.${NC}\n"; continue; }

    local d_count
    d_count=$(echo "$drives_col" | jq -r '."Members@odata.count" // (.Members | length)')
    echo -e "  Found ${BLD}${d_count}${NC} drive(s) under ${drives_path}"

    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
      printf "  ${BLD}%-9s %-24s %-14s %-6s %-9s %-11s %-9s %-7s${NC}\n" \
        "Bay" "Model" "Serial" "Type" "Health" "State" "SSDWear%" "Cap(GB)"
      printf "  %s\n" "$(printf '─%.0s' {1..90})"
    fi

    while IFS= read -r drive_uri; do
      local drive_path="${drive_uri#https://${ILO_HOST}/redfish/v1}"
      drive_path="${drive_path#/redfish/v1}"
      [[ "$drive_path" != /* ]] && drive_path="/${drive_path}"

      local dj
      dj=$(ilo_get "$drive_path")
      [[ -z "$dj" ]] && continue

      local loc model serial media health state cap fw fail ssd
      loc=$(echo "$dj"    | jq -r '.Location // "N/A"')
      model=$(echo "$dj"  | jq -r '.Model // "N/A"')
      serial=$(echo "$dj" | jq -r '.SerialNumber // "N/A"')
      media=$(echo "$dj"  | jq -r '.MediaType // "N/A"')
      health=$(echo "$dj" | jq -r '.Status.Health // "N/A"')
      state=$(echo "$dj"  | jq -r '.Status.State // "N/A"')
      fail=$(echo "$dj"   | jq -r '.FailurePredicted // "false"')
      fw=$(parse_fw "$(echo "$dj" | jq -c '.FirmwareVersion // "N/A"')")
      cap=$(echo "$dj" | jq -r '
        if .CapacityGB then (.CapacityGB|tostring)
        elif .CapacityMiB then ((.CapacityMiB/1024)|floor|tostring)
        else "N/A" end')

      # OEM field: % USED (0-100)
      ssd=$(echo "$dj" | jq -r '.SSDEnduranceUtilizationPercentage // empty')
      [[ -z "$ssd" ]] && ssd="N/A"

      add_drive "$ctrl_name" "$loc" "$model" "$serial" "$media" \
                "$health" "$state" "$ssd" "$cap" "$fw" "$fail"
      any_drives=true
    done <<< "$drive_uris"
    echo ""
  done <<< "$ctrl_uris"

  [[ "$any_drives" == true ]]
}

# ==============================================================================
# PATH B — DMTF Redfish Storage (iLO 5 late firmware / iLO 6)
#   /redfish/v1/Systems/1/Storage/
#     → [storageId] → Drives[*]["@odata.id"]
#         → individual Drive resources
# ==============================================================================
collect_dmtf_storage() {
  echo -e "${BLD}[PATH-B]${NC} DMTF Storage — /Systems/1/Storage/"

  local stor_col stor_uris
  stor_col=$(ilo_get "/Systems/1/Storage/")
  [[ -z "$stor_col" ]] && { echo -e "  ${YLW}Not available on this iLO.${NC}"; return 1; }

  stor_uris=$(echo "$stor_col" | jq -r '.Members[]."@odata.id" // empty')
  [[ -z "$stor_uris" ]] && { echo -e "  ${YLW}No storage subsystems found.${NC}"; return 1; }

  local stor_count any_drives=false
  stor_count=$(echo "$stor_col" | jq -r '."Members@odata.count" // (.Members | length)')
  echo -e "  Found ${BLD}${stor_count}${NC} storage subsystem(s).\n"

  while IFS= read -r stor_uri; do
    local stor_path="${stor_uri#https://${ILO_HOST}/redfish/v1}"
    stor_path="${stor_path#/redfish/v1}"
    [[ "$stor_path" != /* ]] && stor_path="/${stor_path}"

    local stor_json
    stor_json=$(ilo_get "$stor_path")
    [[ -z "$stor_json" ]] && continue

    # Controller name — check multiple schema locations
    local ctrl_name ctrl_health ctrl_fw ctrl_loc
    ctrl_name=$(echo "$stor_json" | jq -r '
      (.StorageControllers[0].Name //
       .StorageControllers[0].Model //
       .Name // "Unknown") | ltrimstr("#")' 2>/dev/null)
    ctrl_health=$(echo "$stor_json" | jq -r '.Status.Health // "N/A"')
    ctrl_fw=$(echo "$stor_json" | jq -r '
      .StorageControllers[0].FirmwareVersion //
      .StorageControllers[0].FirmwarePackageVersion // "N/A"')
    ctrl_loc=$(echo "$stor_json" | jq -r '
      .StorageControllers[0].Location.PartLocation.ServiceLabel //
      .StorageControllers[0].Location.PartLocation.LocationOrdinalValue //
      "N/A"' 2>/dev/null)

    echo -e "  ${BLD}Storage     :${NC} ${ctrl_name}  (ID: $(basename "$stor_path"))"
    echo -e "  ${BLD}FW          :${NC} ${ctrl_fw}   ${BLD}Location:${NC} ${ctrl_loc}"
    printf  "  ${BLD}Health      :${NC} "; color_health "$ctrl_health"; echo -e "\n"

    # Drives are listed inline as an array of {"@odata.id": "…"}
    local drive_uris
    drive_uris=$(echo "$stor_json" | jq -r '.Drives[]."@odata.id" // empty' 2>/dev/null)
    [[ -z "$drive_uris" ]] && { echo -e "  ${YLW}No drives listed in this storage subsystem.${NC}\n"; continue; }

    local d_count
    d_count=$(echo "$stor_json" | jq '[.Drives[]] | length')
    echo -e "  Found ${BLD}${d_count}${NC} drive(s)."

    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
      printf "  ${BLD}%-9s %-24s %-14s %-6s %-9s %-11s %-9s %-7s${NC}\n" \
        "Bay" "Model" "Serial" "Type" "Health" "State" "SSDWear%" "Cap(GB)"
      printf "  %s\n" "$(printf '─%.0s' {1..90})"
    fi

    while IFS= read -r drive_uri; do
      local drive_path="${drive_uri#https://${ILO_HOST}/redfish/v1}"
      drive_path="${drive_path#/redfish/v1}"
      [[ "$drive_path" != /* ]] && drive_path="/${drive_path}"

      local dj
      dj=$(ilo_get "$drive_path")
      [[ -z "$dj" ]] && continue

      local loc model serial media health state cap fw fail ssd life_left
      # Location: DMTF uses PhysicalLocation or Oem.Hpe fields
      loc=$(echo "$dj" | jq -r '
        .PhysicalLocation.PartLocation.ServiceLabel //
        .Location.PartLocation.ServiceLabel //
        .Oem.Hpe.Location //
        .Location //
        "N/A"' 2>/dev/null)
      model=$(echo "$dj"  | jq -r '.Model // .Name // "N/A"')
      serial=$(echo "$dj" | jq -r '.SerialNumber // "N/A"')
      media=$(echo "$dj"  | jq -r '.MediaType // "N/A"')
      health=$(echo "$dj" | jq -r '.Status.Health // "N/A"')
      state=$(echo "$dj"  | jq -r '.Status.State // "N/A"')
      fail=$(echo "$dj"   | jq -r '.FailurePredicted // "false"')
      fw=$(echo "$dj"     | jq -r '.Revision // "N/A"')
      cap=$(echo "$dj" | jq -r '
        if .CapacityBytes then ((.CapacityBytes/1073741824)|floor|tostring)
        elif .CapacityGB  then (.CapacityGB|tostring)
        elif .CapacityMiB then ((.CapacityMiB/1024)|floor|tostring)
        else "N/A" end')

      # DMTF field: PredictedMediaLifeLeftPercent = % REMAINING (invert → % used)
      # Also try OEM field as fallback
      life_left=$(echo "$dj" | jq -r '.PredictedMediaLifeLeftPercent // empty')
      if [[ -n "$life_left" && "$life_left" != "null" ]]; then
        ssd=$(echo "100 - $life_left" | bc)
      else
        ssd=$(echo "$dj" | jq -r '.Oem.Hpe.SSDEnduranceUtilizationPercentage // empty')
        [[ -z "$ssd" ]] && ssd="N/A"
      fi

      add_drive "$ctrl_name" "$loc" "$model" "$serial" "$media" \
                "$health" "$state" "$ssd" "$cap" "$fw" "$fail"
      any_drives=true
    done <<< "$drive_uris"
    echo ""
  done <<< "$stor_uris"

  [[ "$any_drives" == true ]]
}

# ==============================================================================
# Output renderers
# ==============================================================================
render_json() {
  echo "["
  local idx=0
  for row in "${ROWS[@]}"; do
    IFS='|' read -r ctrl loc model serial media health state ssd cap fw fail <<< "$row"
    (( idx++ )) || true
    local sep=$( [[ $idx -lt ${#ROWS[@]} ]] && echo "," || echo "")
    printf '  {\n'
    printf '    "controller": %s,\n'                          "$(echo "$ctrl"   | jq -Rs .)"
    printf '    "location": %s,\n'                            "$(echo "$loc"    | jq -Rs .)"
    printf '    "model": %s,\n'                               "$(echo "$model"  | jq -Rs .)"
    printf '    "serialNumber": %s,\n'                        "$(echo "$serial" | jq -Rs .)"
    printf '    "mediaType": %s,\n'                           "$(echo "$media"  | jq -Rs .)"
    printf '    "health": %s,\n'                              "$(echo "$health" | jq -Rs .)"
    printf '    "state": %s,\n'                               "$(echo "$state"  | jq -Rs .)"
    printf '    "SSDEnduranceUsedPercent": %s,\n'             "$(echo "$ssd"    | jq -Rs .)"
    printf '    "capacityGB": %s,\n'                          "$(echo "$cap"    | jq -Rs .)"
    printf '    "firmwareVersion": %s,\n'                     "$(echo "$fw"     | jq -Rs .)"
    printf '    "failurePredicted": %s\n'                     "$(echo "$fail"   | jq -Rs .)"
    printf '  }%s\n' "$sep"
  done
  echo "]"
}

render_csv() {
  echo "Controller,Location,Model,SerialNumber,MediaType,Health,State,SSDEnduranceUsed%,CapacityGB,FirmwareVersion,FailurePredicted"
  for row in "${ROWS[@]}"; do echo "${row//|/,}"; done
}

render_summary() {
  echo -e "${BLD}${CYN}══════════════════════════ SUMMARY ══════════════════════════${NC}"
  printf "  %-24s %d\n" "Total Drives:"       "$TOTAL"
  printf "  %-24s " "Unhealthy / Failed:"
  [[ $UNHEALTHY -gt 0 ]] && echo -e "${RED}${UNHEALTHY}${NC}" || echo -e "${GRN}${UNHEALTHY}${NC}"
  printf "  %-24s " "SSD Wear Alerts:"
  [[ $SSD_ISSUES -gt 0 ]] && echo -e "${YLW}${SSD_ISSUES}${NC}" || echo -e "${GRN}${SSD_ISSUES}${NC}"
  echo ""
}

# ==============================================================================
# MAIN
# ==============================================================================
echo ""
echo -e "${BLD}${CYN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}${CYN}║   HPE iLO 4/5/6 — Disk Drive Health & SSD Endurance Check   ║${NC}"
echo -e "${BLD}${CYN}╚═══════════════════════════════════════════════════════════════╝${NC}"
printf "  %-16s %s\n" "Target:"    "$ILO_HOST"
printf "  %-16s %s\n" "User:"      "$USERNAME"
printf "  %-16s %s\n" "Time:"      "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-16s warn≥%s%%  crit≥%s%%\n" "SSD Thresholds:" "$WARN_THRESHOLD" "$CRIT_THRESHOLD"
[[ "$DEBUG" == true ]] && echo -e "  ${YLW}Debug ON — raw JSON to stderr${NC}"
echo ""

# ── Detect iLO version ────────────────────────────────────────────────────────
echo -e "${BLD}[Step 1]${NC} Detecting iLO version..."

ILO_VER=$(detect_ilo_version)
if [[ "$ILO_VER" == "unknown" ]]; then
  echo -e "${RED}[ERROR]${NC} Cannot connect to ${ILO_HOST}. Check IP, credentials, and network."
  exit 4
fi

# Print iLO firmware info
MGR_JSON=$(ilo_get "/Managers/1/")
ILO_FW=$(echo "$MGR_JSON" | jq -r '
  .FirmwareVersion //
  .Oem.Hp.Firmware.Current.VersionString //
  .Oem.Hpe.Firmware.Current.VersionString //
  "N/A"')
ILO_MODEL=$(echo "$MGR_JSON" | jq -r '.Model // "iLO"')

echo -e "  Detected: ${BLD}${ILO_MODEL}${NC} — Firmware: ${BLD}${ILO_FW}${NC}"
echo -e "  Strategy: ${BLD}iLO ${ILO_VER}${NC}"
echo ""

# ── Collect drives using appropriate strategy ─────────────────────────────────
echo -e "${BLD}[Step 2]${NC} Collecting drive information...\n"

FOUND_DRIVES=false

case "$ILO_VER" in
  4)
    # iLO 4: OEM SmartStorage only
    collect_oem_smartstorage && FOUND_DRIVES=true
    ;;
  5|4or5)
    # iLO 5: Try OEM SmartStorage first; DMTF path is a fallback
    if collect_oem_smartstorage; then
      FOUND_DRIVES=true
    else
      echo -e "  ${YLW}OEM SmartStorage unavailable; falling back to DMTF Storage...${NC}\n"
      collect_dmtf_storage && FOUND_DRIVES=true
    fi
    ;;
  6|*)
    # iLO 6+: DMTF Storage only
    collect_dmtf_storage && FOUND_DRIVES=true
    ;;
esac

# ── Render final output ───────────────────────────────────────────────────────
case "$OUTPUT_FORMAT" in
  table) render_summary ;;
  json)  render_json    ;;
  csv)   render_csv     ;;
  *)
    echo -e "${RED}[ERROR]${NC} Unknown format '${OUTPUT_FORMAT}'. Use: table | json | csv"
    exit 1 ;;
esac

# ── Exit code ─────────────────────────────────────────────────────────────────
if [[ "$FOUND_DRIVES" == false || "$TOTAL" -eq 0 ]]; then
  echo -e "${YLW}[WARN]${NC} No drives found."
  echo -e "  Tip: re-run with ${BLD}-d${NC} to inspect raw Redfish responses."
  exit 3
elif [[ $UNHEALTHY -gt 0 || $SSD_ISSUES -gt 0 ]]; then
  echo -e "${RED}[ACTION REQUIRED]${NC} One or more drives need attention — review output above."
  exit 2
fi
echo -e "${GRN}[OK]${NC} All ${TOTAL} drive(s) healthy. No SSD endurance alerts."
exit 0

