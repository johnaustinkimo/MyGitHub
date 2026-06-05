#!/bin/bash
# =============================================================================
# check_smartstorage_health.sh
# Description : Check HPE SmartStorage disk drive SSDEnduranceUtilizationPercentage
#               and disk health via HPE iLO Redfish API
# Usage       : ./check_smartstorage_health.sh -H <iLO_IP> -u <username> -p <password> [OPTIONS]
# =============================================================================

set -euo pipefail

# ---------- Color codes ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------- Defaults ----------
ILO_HOST=""
USERNAME=""
PASSWORD=""
VERIFY_SSL="--insecure"   # Use "" to enforce SSL cert verification
OUTPUT_FORMAT="table"     # table | json | csv
WARN_THRESHOLD=70         # % SSD wear warning
CRIT_THRESHOLD=90         # % SSD wear critical
TIMEOUT=30
VERBOSE=false

# ---------- Usage ----------
usage() {
  cat <<EOF
${BOLD}Usage:${NC}
  $(basename "$0") -H <iLO_IP> -u <username> -p <password> [OPTIONS]

${BOLD}Required:${NC}
  -H  iLO hostname or IP address
  -u  iLO username
  -p  iLO password

${BOLD}Options:${NC}
  -o  Output format: table (default), json, csv
  -w  SSD endurance warning threshold  (default: ${WARN_THRESHOLD}%)
  -c  SSD endurance critical threshold (default: ${CRIT_THRESHOLD}%)
  -t  HTTP timeout in seconds          (default: ${TIMEOUT}s)
  -s  Enable SSL certificate verification (disabled by default)
  -v  Verbose / debug mode
  -h  Show this help

${BOLD}Examples:${NC}
  $(basename "$0") -H 192.168.1.100 -u Administrator -p MyPass
  $(basename "$0") -H ilo.server.local -u admin -p pass -o csv -w 60 -c 85
EOF
  exit 0
}

# ---------- Argument parsing ----------
while getopts "H:u:p:o:w:c:t:svh" opt; do
  case $opt in
    H) ILO_HOST="$OPTARG" ;;
    u) USERNAME="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;
    o) OUTPUT_FORMAT="$OPTARG" ;;
    w) WARN_THRESHOLD="$OPTARG" ;;
    c) CRIT_THRESHOLD="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    s) VERIFY_SSL="" ;;
    v) VERBOSE=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# ---------- Validate required args ----------
if [[ -z "$ILO_HOST" || -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo -e "${RED}[ERROR]${NC} Missing required arguments. Use -h for help."
  exit 1
fi

# ---------- Dependency check ----------
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Required command not found: ${BOLD}${cmd}${NC}"
    echo "  Install with:  sudo apt install ${cmd}   OR   sudo yum install ${cmd}"
    exit 1
  fi
done

BASE_URL="https://${ILO_HOST}/redfish/v1"
CURL_OPTS=(
  --silent
  --show-error
  --connect-timeout "$TIMEOUT"
  --max-time "$TIMEOUT"
  --header "Content-Type: application/json"
  --header "Accept: application/json"
  --user "${USERNAME}:${PASSWORD}"
)
[[ -n "$VERIFY_SSL" ]] || CURL_OPTS+=("--insecure")
[[ "$VERBOSE" == true ]] && CURL_OPTS+=("--verbose")

# ---------- Helper: safe curl with error handling ----------
redfish_get() {
  local url="$1"
  local response http_code body

  response=$(curl "${CURL_OPTS[@]}" \
    --write-out "\n__HTTP_CODE__%{http_code}" \
    "$url" 2>&1) || {
    echo -e "${RED}[ERROR]${NC} curl failed for: $url" >&2
    return 1
  }

  http_code=$(echo "$response" | grep -o '__HTTP_CODE__[0-9]*' | sed 's/__HTTP_CODE__//')
  body=$(echo "$response" | sed '/__HTTP_CODE__/d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo -e "${RED}[ERROR]${NC} HTTP ${http_code} for: $url" >&2
    [[ "$VERBOSE" == true ]] && echo "$body" >&2
    return 1
  fi

  echo "$body"
}

# ---------- Status color helper ----------
health_color() {
  case "$1" in
    OK)       echo -e "${GREEN}$1${NC}" ;;
    Warning)  echo -e "${YELLOW}$1${NC}" ;;
    Critical) echo -e "${RED}$1${NC}" ;;
    *)        echo -e "${CYAN}$1${NC}" ;;
  esac
}

endurance_color() {
  local pct="$1"
  if [[ "$pct" == "N/A" ]]; then echo "$pct"; return; fi
  if   (( $(echo "$pct >= $CRIT_THRESHOLD" | bc -l) )); then echo -e "${RED}${pct}%${NC}"
  elif (( $(echo "$pct >= $WARN_THRESHOLD" | bc -l) )); then echo -e "${YELLOW}${pct}%${NC}"
  else echo -e "${GREEN}${pct}%${NC}"
  fi
}

# =============================================================================
# MAIN LOGIC
# =============================================================================

echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${WHITE}  HPE SmartStorage Disk Health & SSD Endurance Check${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "  Target : ${ILO_HOST}"
echo -e "  User   : ${USERNAME}"
echo -e "  Time   : $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ---------- Step 1: Find SmartStorage controller(s) ----------
echo -e "${BOLD}[1/3]${NC} Discovering SmartStorage controllers..."

SMARTSTORAGE_URL="${BASE_URL}/Systems/1/SmartStorage"
SS_ROOT=$(redfish_get "$SMARTSTORAGE_URL") || {
  echo -e "${RED}[ERROR]${NC} Cannot reach SmartStorage endpoint. Is this an HPE iLO server?"
  exit 1
}

# Array Controllers link
ARRAY_CTRL_URL=$(echo "$SS_ROOT" | jq -r '.Links.ArrayControllers["@odata.id"] // .Links.ArrayControllers.href // empty')
if [[ -z "$ARRAY_CTRL_URL" ]]; then
  echo -e "${RED}[ERROR]${NC} No ArrayControllers link found in SmartStorage root."
  exit 1
fi
ARRAY_CTRL_URL="https://${ILO_HOST}${ARRAY_CTRL_URL}"

CTRL_COLLECTION=$(redfish_get "$ARRAY_CTRL_URL")
CTRL_MEMBERS=$(echo "$CTRL_COLLECTION" | jq -r '.Members[]."@odata.id" // .Members[].href')

if [[ -z "$CTRL_MEMBERS" ]]; then
  echo -e "${YELLOW}[WARN]${NC} No array controllers found."
  exit 0
fi

CTRL_COUNT=$(echo "$CTRL_MEMBERS" | wc -l)
echo -e "  Found ${BOLD}${CTRL_COUNT}${NC} controller(s)."

# ---------- Step 2: Enumerate all disk drives ----------
echo -e "${BOLD}[2/3]${NC} Enumerating disk drives..."

declare -a DISK_RESULTS=()   # stores TSV: Controller|Location|Model|SerialNo|MediaType|HealthStatus|State|SSDEndurance|CapacityGB
TOTAL_DISKS=0
UNHEALTHY=0
SSD_WARN=0

while IFS= read -r CTRL_PATH; do
  CTRL_URL="https://${ILO_HOST}${CTRL_PATH}"
  CTRL_DATA=$(redfish_get "$CTRL_URL") || continue

  CTRL_NAME=$(echo "$CTRL_DATA" | jq -r '.Model // .Name // "Unknown Controller"')
  CTRL_HEALTH=$(echo "$CTRL_DATA" | jq -r '.Status.Health // "Unknown"')
  CTRL_LOCATION=$(echo "$CTRL_DATA" | jq -r '.Location // "Slot ?"')

  echo -e "  Controller: ${BOLD}${CTRL_NAME}${NC}  Location: ${CTRL_LOCATION}  Health: $(health_color "$CTRL_HEALTH")"

  # Physical drives link
  DRIVES_URL=$(echo "$CTRL_DATA" | jq -r '.Links.PhysicalDrives["@odata.id"] // .Links.PhysicalDrives.href // empty')
  [[ -z "$DRIVES_URL" ]] && { echo -e "    ${YELLOW}No PhysicalDrives link found.${NC}"; continue; }

  DRIVES_URL="https://${ILO_HOST}${DRIVES_URL}"
  DRIVES_COLLECTION=$(redfish_get "$DRIVES_URL") || continue
  DRIVE_MEMBERS=$(echo "$DRIVES_COLLECTION" | jq -r '.Members[]."@odata.id" // .Members[].href // empty')

  [[ -z "$DRIVE_MEMBERS" ]] && { echo -e "    ${YELLOW}No drives found under this controller.${NC}"; continue; }

  while IFS= read -r DRIVE_PATH; do
    DRIVE_URL="https://${ILO_HOST}${DRIVE_PATH}"
    DRIVE_DATA=$(redfish_get "$DRIVE_URL") || continue

    LOCATION=$(echo "$DRIVE_DATA"   | jq -r '.Location // "N/A"')
    MODEL=$(echo "$DRIVE_DATA"      | jq -r '.Model // "N/A"')
    SERIAL=$(echo "$DRIVE_DATA"     | jq -r '.SerialNumber // "N/A"')
    MEDIA_TYPE=$(echo "$DRIVE_DATA" | jq -r '.MediaType // "N/A"')
    HEALTH=$(echo "$DRIVE_DATA"     | jq -r '.Status.Health // "Unknown"')
    STATE=$(echo "$DRIVE_DATA"      | jq -r '.Status.State // "Unknown"')
    CAP_GB=$(echo "$DRIVE_DATA"     | jq -r 'if .CapacityGB then .CapacityGB elif .CapacityMiB then (.CapacityMiB / 1024 | floor) else "N/A" end')

    # SSD endurance — may appear under different field names across iLO versions
    SSD_END=$(echo "$DRIVE_DATA" | jq -r '
      .SSDEnduranceUtilizationPercentage //
      .SSDEndurancePercent //
      .PredictiveFailureCount //
      null
    ')
    [[ "$SSD_END" == "null" || -z "$SSD_END" ]] && SSD_END="N/A"

    # Track counts
    (( TOTAL_DISKS++ )) || true
    [[ "$HEALTH" != "OK" ]] && (( UNHEALTHY++ )) || true

    if [[ "$SSD_END" != "N/A" ]]; then
      if (( $(echo "$SSD_END >= $CRIT_THRESHOLD" | bc -l) )); then (( SSD_WARN++ )) || true
      elif (( $(echo "$SSD_END >= $WARN_THRESHOLD" | bc -l) )); then (( SSD_WARN++ )) || true
      fi
    fi

    DISK_RESULTS+=("${CTRL_NAME}|${LOCATION}|${MODEL}|${SERIAL}|${MEDIA_TYPE}|${HEALTH}|${STATE}|${SSD_END}|${CAP_GB}")
  done <<< "$DRIVE_MEMBERS"

done <<< "$CTRL_MEMBERS"

# ---------- Step 3: Output results ----------
echo ""
echo -e "${BOLD}[3/3]${NC} Results — ${TOTAL_DISKS} drive(s) found"
echo ""

case "$OUTPUT_FORMAT" in
  # ---- TABLE ----
  table)
    printf "${BOLD}%-22s %-10s %-26s %-16s %-8s %-10s %-12s %-12s %-8s${NC}\n" \
      "Controller" "Location" "Model" "Serial" "Type" "Health" "State" "SSD Wear%" "Cap(GB)"
    printf '%s\n' "$(printf '─%.0s' {1..120})"

    for row in "${DISK_RESULTS[@]}"; do
      IFS='|' read -r ctrl loc model serial mtype health state ssdpct cap <<< "$row"
      # plain text for printf width alignment; colors appended separately
      printf "%-22s %-10s %-26s %-16s %-8s " \
        "${ctrl:0:21}" "${loc:0:9}" "${model:0:25}" "${serial:0:15}" "${mtype:0:7}"
      printf "%-10s %-12s %-12s %-8s\n" \
        "$(health_color "$health")" \
        "$state" \
        "$(endurance_color "$ssdpct")" \
        "$cap"
    done

    echo ""
    printf '%s\n' "$(printf '─%.0s' {1..120})"
    echo -e "  Total Drives : ${BOLD}${TOTAL_DISKS}${NC}"
    echo -e "  Unhealthy    : $([ "$UNHEALTHY" -gt 0 ] && echo -e "${RED}${UNHEALTHY}${NC}" || echo -e "${GREEN}${UNHEALTHY}${NC}")"
    echo -e "  SSD Warnings : $([ "$SSD_WARN"   -gt 0 ] && echo -e "${YELLOW}${SSD_WARN}${NC}"  || echo -e "${GREEN}${SSD_WARN}${NC}")"
    ;;

  # ---- JSON ----
  json)
    echo "["
    count=0
    for row in "${DISK_RESULTS[@]}"; do
      IFS='|' read -r ctrl loc model serial mtype health state ssdpct cap <<< "$row"
      (( count++ )) || true
      sep=$( [[ $count -lt ${#DISK_RESULTS[@]} ]] && echo "," || echo "" )
      cat <<JSONROW
  {
    "controller": "${ctrl}",
    "location": "${loc}",
    "model": "${model}",
    "serialNumber": "${serial}",
    "mediaType": "${mtype}",
    "health": "${health}",
    "state": "${state}",
    "SSDEnduranceUtilizationPercentage": "${ssdpct}",
    "capacityGB": "${cap}"
  }${sep}
JSONROW
    done
    echo "]"
    ;;

  # ---- CSV ----
  csv)
    echo "Controller,Location,Model,SerialNumber,MediaType,Health,State,SSDEndurance%,CapacityGB"
    for row in "${DISK_RESULTS[@]}"; do
      echo "${row//|/,}"
    done
    ;;

  *)
    echo -e "${RED}[ERROR]${NC} Unknown output format: ${OUTPUT_FORMAT}. Use table, json, or csv."
    exit 1
    ;;
esac

echo ""

# ---------- Exit code ----------
if [[ "$UNHEALTHY" -gt 0 || "$SSD_WARN" -gt 0 ]]; then
  echo -e "${YELLOW}[WARN]${NC} One or more issues detected. Review the results above."
  exit 2
fi

echo -e "${GREEN}[OK]${NC} All drives healthy. No SSD endurance warnings."
exit 0

