#!/bin/bash
# =============================================================================
# check_smartstorage_ilo5.sh
# Description : Check HPE iLO 5 SmartStorage disk drive health and
#               SSDEnduranceUtilizationPercentage via Redfish API
#
# Correct iLO 5 API path:
#   /redfish/v1/Systems/1/SmartStorage/ArrayControllers/
#   /redfish/v1/Systems/1/SmartStorage/ArrayControllers/{id}/DiskDrives/
#   /redfish/v1/Systems/1/SmartStorage/ArrayControllers/{id}/DiskDrives/{id}/
#
# Usage : ./check_smartstorage_ilo5.sh -H <iLO_IP> -u <user> -p <pass> [OPTIONS]
# Requires: curl, jq
# =============================================================================

# ---------- Color codes ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'; NC='\033[0m'

# ---------- Defaults ----------
ILO_HOST=""; USERNAME=""; PASSWORD=""
OUTPUT_FORMAT="table"   # table | json | csv
WARN_THRESHOLD=70       # SSD wear % warning
CRIT_THRESHOLD=90       # SSD wear % critical
TIMEOUT=30
LOG_FILE=""

usage() {
  cat <<EOF
${BOLD}HPE iLO 5 SmartStorage Disk Health Checker${NC}

Usage: $(basename "$0") -H <iLO_IP> -u <username> -p <password> [OPTIONS]

${BOLD}Required:${NC}
  -H  iLO hostname or IP
  -u  iLO username
  -p  iLO password

${BOLD}Options:${NC}
  -o  Output format: table (default) | json | csv
  -w  SSD endurance WARN threshold  (default: ${WARN_THRESHOLD}%)
  -c  SSD endurance CRIT threshold  (default: ${CRIT_THRESHOLD}%)
  -t  HTTP timeout seconds          (default: ${TIMEOUT})
  -l  Log output to file
  -h  Show help

${BOLD}Examples:${NC}
  $(basename "$0") -H 10.0.0.50 -u Administrator -p Admin123
  $(basename "$0") -H 10.0.0.50 -u Administrator -p Admin123 -o csv -l /var/log/disk_health.log
  $(basename "$0") -H 10.0.0.50 -u Administrator -p Admin123 -w 60 -c 85 -o json
EOF
  exit 0
}

while getopts "H:u:p:o:w:c:t:l:h" opt; do
  case $opt in
    H) ILO_HOST="$OPTARG" ;;   u) USERNAME="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;   o) OUTPUT_FORMAT="$OPTARG" ;;
    w) WARN_THRESHOLD="$OPTARG" ;; c) CRIT_THRESHOLD="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;    l) LOG_FILE="$OPTARG" ;;
    h) usage ;;                *) usage ;;
  esac
done

[[ -z "$ILO_HOST" || -z "$USERNAME" || -z "$PASSWORD" ]] && {
  echo -e "${RED}[ERROR]${NC} -H, -u, -p are required. Use -h for help."; exit 1; }

for cmd in curl jq bc; do
  command -v "$cmd" &>/dev/null || {
    echo -e "${RED}[ERROR]${NC} Missing: ${cmd}. Install: sudo apt/yum install ${cmd}"; exit 1; }
done

# ---------- Tee to log if -l given ----------
[[ -n "$LOG_FILE" ]] && exec > >(tee -a "$LOG_FILE") 2>&1

BASE="https://${ILO_HOST}/redfish/v1"

# ---------- curl wrapper ----------
# Usage: ilo_get <path>   (path starts with /)
ilo_get() {
  local path="$1"
  local url="${BASE}${path}"
  local out
  out=$(curl --silent --insecure \
             --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
             --user "${USERNAME}:${PASSWORD}" \
             --header "Accept: application/json" \
             "$url") || { echo "CURL_FAIL"; return 1; }

  # Check for Redfish error payload
  if echo "$out" | jq -e '.error' &>/dev/null; then
    echo "REDFISH_ERROR: $(echo "$out" | jq -r '.error.message // .error.code')" >&2
    echo "CURL_FAIL"; return 1
  fi
  echo "$out"
}

# ---------- Health color ----------
hc() {
  case "$1" in
    OK)       printf "${GREEN}%-10s${NC}" "$1" ;;
    Warning)  printf "${YELLOW}%-10s${NC}" "$1" ;;
    Critical|Failed) printf "${RED}%-10s${NC}" "$1" ;;
    *)        printf "${CYAN}%-10s${NC}" "$1" ;;
  esac
}

# ---------- SSD endurance color ----------
ec() {
  local v="$1"
  [[ "$v" == "N/A" ]] && { printf "%-10s" "N/A"; return; }
  if   (( $(echo "$v >= $CRIT_THRESHOLD" | bc -l) )); then printf "${RED}%-10s${NC}" "${v}%"
  elif (( $(echo "$v >= $WARN_THRESHOLD" | bc -l) )); then printf "${YELLOW}%-10s${NC}" "${v}%"
  else printf "${GREEN}%-10s${NC}" "${v}%"
  fi
}

# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   HPE iLO 5 — SmartStorage Disk Health & SSD Endurance  ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
printf "  %-12s %s\n" "Target:"   "$ILO_HOST"
printf "  %-12s %s\n" "User:"     "$USERNAME"
printf "  %-12s %s\n" "Time:"     "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-12s warn≥%s%%  crit≥%s%%\n" "SSD Thresholds:" "$WARN_THRESHOLD" "$CRIT_THRESHOLD"
echo ""

# ── Step 1: Get Array Controllers ─────────────────────────────────────────────
echo -e "${BOLD}[Step 1]${NC} Querying SmartStorage Array Controllers..."

CTRL_COL=$(ilo_get "/Systems/1/SmartStorage/ArrayControllers/")
if [[ "$CTRL_COL" == "CURL_FAIL" || -z "$CTRL_COL" ]]; then
  echo -e "${RED}[ERROR]${NC} Cannot reach /redfish/v1/Systems/1/SmartStorage/ArrayControllers/"
  echo "        Check: iLO IP, credentials, and that this is a Gen9/Gen10 HPE server with iLO 5."
  exit 1
fi

# Members can be "@odata.id" keys
CTRL_IDS=$(echo "$CTRL_COL" | jq -r '.Members[]."@odata.id"' 2>/dev/null)
CTRL_COUNT=$(echo "$CTRL_COL" | jq -r '."Members@odata.count" // .Members | length' 2>/dev/null)

if [[ -z "$CTRL_IDS" ]]; then
  echo -e "${YELLOW}[WARN]${NC} No array controllers found."
  exit 0
fi
echo -e "  Found ${BOLD}${CTRL_COUNT}${NC} controller(s)."
echo ""

# ── Step 2: Walk each controller → DiskDrives ─────────────────────────────────
echo -e "${BOLD}[Step 2]${NC} Enumerating disk drives..."
echo ""

declare -a ROWS=()
TOTAL=0; UNHEALTHY=0; SSD_ISSUES=0

while IFS= read -r CTRL_ODATA; do
  # Extract relative path: /redfish/v1/Systems/1/SmartStorage/ArrayControllers/0
  # We need everything after /redfish/v1
  CTRL_PATH="${CTRL_ODATA#/redfish/v1}"

  CTRL_DATA=$(ilo_get "$CTRL_PATH")
  [[ "$CTRL_DATA" == "CURL_FAIL" ]] && { echo "  [SKIP] $CTRL_PATH"; continue; }

  CTRL_NAME=$(echo "$CTRL_DATA"     | jq -r '.Model // .Name // "Unknown"')
  CTRL_HEALTH=$(echo "$CTRL_DATA"   | jq -r '.Status.Health // "Unknown"')
  CTRL_SN=$(echo "$CTRL_DATA"       | jq -r '.SerialNumber // "N/A"')
  CTRL_FW=$(echo "$CTRL_DATA"       | jq -r '.FirmwareVersion // "N/A"')
  CTRL_LOCATION=$(echo "$CTRL_DATA" | jq -r '.Location // "N/A"')

  echo -e "  ${BOLD}Controller :${NC} $CTRL_NAME"
  echo -e "  ${BOLD}Serial     :${NC} $CTRL_SN   ${BOLD}FW:${NC} $CTRL_FW   ${BOLD}Location:${NC} $CTRL_LOCATION"
  echo -e "  ${BOLD}Health     :${NC} $(hc "$CTRL_HEALTH")"
  echo ""

  # ── DiskDrives collection under this controller ──────────────────────────
  # iLO 5 path: <controller_path>/DiskDrives/
  DISKDRIVES_PATH="${CTRL_PATH}/DiskDrives/"
  DD_COL=$(ilo_get "$DISKDRIVES_PATH")

  if [[ "$DD_COL" == "CURL_FAIL" ]]; then
    echo -e "    ${YELLOW}[WARN]${NC} Could not fetch DiskDrives for this controller."
    echo ""
    continue
  fi

  DRIVE_ODATAS=$(echo "$DD_COL" | jq -r '.Members[]."@odata.id"' 2>/dev/null)
  if [[ -z "$DRIVE_ODATAS" ]]; then
    echo -e "    ${YELLOW}No disk drives found under this controller.${NC}"
    echo ""
    continue
  fi

  # Print header for this controller's drives
  if [[ "$OUTPUT_FORMAT" == "table" ]]; then
    printf "    ${BOLD}%-8s %-26s %-14s %-8s %-10s %-10s %-10s %-8s${NC}\n" \
      "Bay" "Model" "Serial" "Type" "Health" "State" "SSDWear%" "Cap(GB)"
    printf "    %s\n" "$(printf '─%.0s' {1..95})"
  fi

  while IFS= read -r DRIVE_ODATA; do
    DRIVE_PATH="${DRIVE_ODATA#/redfish/v1}"
    DRIVE_DATA=$(ilo_get "$DRIVE_PATH")
    [[ "$DRIVE_DATA" == "CURL_FAIL" ]] && continue

    # ── Extract all fields ──────────────────────────────────────────────────
    LOCATION=$(echo "$DRIVE_DATA"   | jq -r '.Location // "N/A"')
    MODEL=$(echo "$DRIVE_DATA"      | jq -r '.Model // "N/A"')
    SERIAL=$(echo "$DRIVE_DATA"     | jq -r '.SerialNumber // "N/A"')
    MEDIA=$(echo "$DRIVE_DATA"      | jq -r '.MediaType // "N/A"')
    HEALTH=$(echo "$DRIVE_DATA"     | jq -r '.Status.Health // "Unknown"')
    STATE=$(echo "$DRIVE_DATA"      | jq -r '.Status.State // "Unknown"')
    INTERFACE=$(echo "$DRIVE_DATA"  | jq -r '.InterfaceType // ""')
    RPM=$(echo "$DRIVE_DATA"        | jq -r '.RotationalSpeedRpm // ""')
    FW=$(echo "$DRIVE_DATA"         | jq -r '.FirmwareVersion // "N/A"')

    # Capacity: prefer CapacityGB, fall back to CapacityMiB → convert
    CAP=$(echo "$DRIVE_DATA" | jq -r '
      if .CapacityGB then (.CapacityGB | tostring)
      elif .CapacityMiB then ((.CapacityMiB / 1024) | floor | tostring)
      elif .CapacityLogicalBlocks then "?"
      else "N/A"
      end')

    # SSD Endurance — iLO 5 field name
    SSD_PCT=$(echo "$DRIVE_DATA" | jq -r \
      '.SSDEnduranceUtilizationPercentage // null')
    [[ "$SSD_PCT" == "null" || -z "$SSD_PCT" ]] && SSD_PCT="N/A"

    # Failure predicted flag
    FAIL_PRED=$(echo "$DRIVE_DATA" | jq -r '.FailurePredicted // null')

    (( TOTAL++ )) || true
    [[ "$HEALTH" != "OK" ]] && (( UNHEALTHY++ )) || true
    if [[ "$SSD_PCT" != "N/A" ]]; then
      (( $(echo "$SSD_PCT >= $WARN_THRESHOLD" | bc -l) )) && (( SSD_ISSUES++ )) || true
    fi
    [[ "$FAIL_PRED" == "true" ]] && (( UNHEALTHY++ )) || true

    ROWS+=("${CTRL_NAME}|${LOCATION}|${MODEL}|${SERIAL}|${MEDIA}|${INTERFACE}|${HEALTH}|${STATE}|${SSD_PCT}|${CAP}|${FW}|${FAIL_PRED}")

    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
      # Warn marker for failure prediction
      FAIL_MARK=""
      [[ "$FAIL_PRED" == "true" ]] && FAIL_MARK=" ${RED}⚠ FAIL_PREDICTED${NC}"

      printf "    %-8s %-26s %-14s %-8s " \
        "${LOCATION:0:7}" "${MODEL:0:25}" "${SERIAL:0:13}" "${MEDIA:0:7}"
      hc "$HEALTH"
      printf " %-12s " "$STATE"
      ec "$SSD_PCT"
      printf " %-8s%b\n" "$CAP" "$FAIL_MARK"
    fi
  done <<< "$DRIVE_ODATAS"

  echo ""
done <<< "$CTRL_IDS"

# ── Step 3: Final output ──────────────────────────────────────────────────────
case "$OUTPUT_FORMAT" in
  table)
    echo -e "${BOLD}${CYAN}══════════════════════ SUMMARY ═══════════════════════${NC}"
    printf "  %-20s %s\n" "Total Drives:"    "$TOTAL"
    printf "  %-20s " "Unhealthy / Failed:"
    [[ "$UNHEALTHY" -gt 0 ]] && echo -e "${RED}${UNHEALTHY}${NC}" || echo -e "${GREEN}${UNHEALTHY}${NC}"
    printf "  %-20s " "SSD Wear Alerts:"
    [[ "$SSD_ISSUES" -gt 0 ]] && echo -e "${YELLOW}${SSD_ISSUES}${NC}" || echo -e "${GREEN}${SSD_ISSUES}${NC}"
    echo ""
    ;;

  json)
    echo "["
    IDX=0
    for row in "${ROWS[@]}"; do
      IFS='|' read -r ctrl loc model serial media iface health state ssd cap fw failpred <<< "$row"
      (( IDX++ )) || true
      SEP=$( [[ $IDX -lt ${#ROWS[@]} ]] && echo "," || echo "" )
      cat <<JSON
  {
    "controller": "${ctrl}",
    "location": "${loc}",
    "model": "${model}",
    "serialNumber": "${serial}",
    "mediaType": "${media}",
    "interfaceType": "${iface}",
    "health": "${health}",
    "state": "${state}",
    "SSDEnduranceUtilizationPercentage": "${ssd}",
    "capacityGB": "${cap}",
    "firmwareVersion": "${fw}",
    "failurePredicted": "${failpred}"
  }${SEP}
JSON
    done
    echo "]"
    ;;

  csv)
    echo "Controller,Location,Model,SerialNumber,MediaType,InterfaceType,Health,State,SSDEndurance%,CapacityGB,FirmwareVersion,FailurePredicted"
    for row in "${ROWS[@]}"; do
      echo "${row//|/,}"
    done
    ;;
esac

# ── Exit code ─────────────────────────────────────────────────────────────────
if [[ "$TOTAL" -eq 0 ]]; then
  echo -e "${YELLOW}[WARN]${NC} No drives found. Verify credentials and server model."
  exit 3
elif [[ "$UNHEALTHY" -gt 0 || "$SSD_ISSUES" -gt 0 ]]; then
  echo -e "${RED}[CRITICAL/WARN]${NC} Issues detected — review output above."
  exit 2
fi
echo -e "${GREEN}[OK]${NC} All ${TOTAL} drive(s) healthy. No SSD endurance warnings."
exit 0

