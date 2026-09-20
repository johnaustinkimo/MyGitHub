#!/usr/bin/env bash
#
# blockchain_firewall_v1.0.sh
#
# RHEL 10 / firewalld
#
# Usage:
#   ./blockchain_firewall_v1.0.sh enable
#   ./blockchain_firewall_v1.0.sh refresh
#   ./blockchain_firewall_v1.0.sh rebuild
#   ./blockchain_firewall_v1.0.sh verify
#   ./blockchain_firewall_v1.0.sh check
#   ./blockchain_firewall_v1.0.sh disable
#
# Managed ports:
#   30303/tcp
#   30303/udp
#   8544/tcp
#

set -u
set -o pipefail

# ============================================================
# CONFIG
# ============================================================

ZONE="drop"
IPSET_NAME="blockchain_allowlist"

LOCK_FILE="/run/blockchain_firewall.lock"
LOG_TAG="blockchain-fw"

ALLOWED_IPS=(
    "10.8.101.1"
    "10.8.101.2"
    "10.8.102.1"
    "10.8.102.101"
    "10.8.103.1"
    "10.8.103.101"
    "10.8.106.101"
    "10.8.106.102"
    "10.8.106.105"
    "10.8.106.111"
    "10.8.106.112"
    "10.8.106.121"
    "10.8.105.1"
    "10.8.105.2"
    "10.8.105.3"
    "10.8.105.4"
    "10.8.105.101"
    "10.8.105.102"
    "10.8.105.103"
    "10.8.105.104"
)

RICH_RULES=(
    "rule family=\"ipv4\" source ipset=\"${IPSET_NAME}\" port port=\"30303\" protocol=\"tcp\" accept"
    "rule family=\"ipv4\" source ipset=\"${IPSET_NAME}\" port port=\"30303\" protocol=\"udp\" accept"
    "rule family=\"ipv4\" source ipset=\"${IPSET_NAME}\" port port=\"8544\" protocol=\"tcp\" accept"
)

# ============================================================
# FUNCTIONS
# ============================================================

log()
{
    local level="$1"
    shift

    local msg="$*"

    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg"
    logger -t "$LOG_TAG" "[$level] $msg"
}


die()
{
    log ERROR "$*"
    exit 1
}


require_root()
{
    if [[ $EUID -ne 0 ]]; then
        die "This script must be executed as root."
    fi
}


check_commands()
{
    local cmd

    for cmd in firewall-cmd systemctl logger flock grep sort; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command not found: $cmd"
    done
}


check_firewalld()
{
    if ! systemctl is-active --quiet firewalld; then
        die "firewalld service is not running."
    fi
}


check_zone()
{
    if ! firewall-cmd --get-zones |
        tr ' ' '\n' |
        grep -Fxq "$ZONE"; then

        die "firewalld zone does not exist: $ZONE"
    fi
}


acquire_lock()
{
    exec 200>"$LOCK_FILE"

    if ! flock -n 200; then
        log WARNING "Another instance is already running."
        exit 0
    fi
}


ipset_exists_permanent()
{
    firewall-cmd --permanent --get-ipsets 2>/dev/null |
        tr ' ' '\n' |
        grep -Fxq "$IPSET_NAME"
}


ipset_exists_runtime()
{
    firewall-cmd --get-ipsets 2>/dev/null |
        tr ' ' '\n' |
        grep -Fxq "$IPSET_NAME"
}


create_ipset()
{
    if ipset_exists_permanent; then
        log INFO "IP set already exists: $IPSET_NAME"
        return 0
    fi

    log INFO "Creating IP set: $IPSET_NAME"

    firewall-cmd \
        --permanent \
        --new-ipset="$IPSET_NAME" \
        --type=hash:ip >/dev/null ||
        die "Failed to create IP set: $IPSET_NAME"
}


ip_is_desired()
{
    local target="$1"
    local ip

    for ip in "${ALLOWED_IPS[@]}"; do
        if [[ "$ip" == "$target" ]]; then
            return 0
        fi
    done

    return 1
}


sync_ipset_entries()
{
    local ip
    local current_ip

    log INFO "Synchronizing IP set entries..."

    #
    # Remove entries that are no longer configured.
    #
    while IFS= read -r current_ip; do

        [[ -z "$current_ip" ]] && continue

        if ! ip_is_desired "$current_ip"; then

            log INFO "Removing stale IP: $current_ip"

            firewall-cmd \
                --permanent \
                --ipset="$IPSET_NAME" \
                --remove-entry="$current_ip" >/dev/null ||
                die "Failed removing stale IP: $current_ip"
        fi

    done < <(
        firewall-cmd \
            --permanent \
            --ipset="$IPSET_NAME" \
            --get-entries 2>/dev/null
    )

    #
    # Add missing entries.
    #
    for ip in "${ALLOWED_IPS[@]}"; do

        if firewall-cmd \
            --permanent \
            --ipset="$IPSET_NAME" \
            --query-entry="$ip" >/dev/null 2>&1; then

            continue
        fi

        log INFO "Adding IP: $ip"

        firewall-cmd \
            --permanent \
            --ipset="$IPSET_NAME" \
            --add-entry="$ip" >/dev/null ||
            die "Failed adding IP: $ip"
    done
}


ensure_rich_rules()
{
    local rule

    log INFO "Checking rich rules..."

    for rule in "${RICH_RULES[@]}"; do

        if firewall-cmd \
            --permanent \
            --zone="$ZONE" \
            --query-rich-rule="$rule" >/dev/null 2>&1; then

            log INFO "Rule already exists: $rule"
            continue
        fi

        log INFO "Adding rule: $rule"

        firewall-cmd \
            --permanent \
            --zone="$ZONE" \
            --add-rich-rule="$rule" >/dev/null ||
            die "Failed adding rich rule: $rule"
    done
}


remove_rich_rules()
{
    local rule

    for rule in "${RICH_RULES[@]}"; do

        if firewall-cmd \
            --permanent \
            --zone="$ZONE" \
            --query-rich-rule="$rule" >/dev/null 2>&1; then

            log INFO "Removing rule: $rule"

            firewall-cmd \
                --permanent \
                --zone="$ZONE" \
                --remove-rich-rule="$rule" >/dev/null ||
                log ERROR "Failed removing rule: $rule"
        fi
    done
}


remove_ipset()
{
    if ! ipset_exists_permanent; then
        return 0
    fi

    log INFO "Removing IP set: $IPSET_NAME"

    firewall-cmd \
        --permanent \
        --delete-ipset="$IPSET_NAME" >/dev/null ||
        die "Failed removing IP set: $IPSET_NAME"
}


reload_firewall()
{
    log INFO "Reloading firewalld..."

    firewall-cmd --reload >/dev/null ||
        die "firewall-cmd --reload failed"
}


verify_configuration()
{
    local failed=0
    local ip
    local rule

    #
    # Permanent IP set
    #
    if ! ipset_exists_permanent; then
        log ERROR "Permanent IP set missing: $IPSET_NAME"
        failed=1
    fi

    #
    # Runtime IP set
    #
    if ! ipset_exists_runtime; then
        log ERROR "Runtime IP set missing: $IPSET_NAME"
        failed=1
    fi

    #
    # Permanent entries
    #
    if ipset_exists_permanent; then

        for ip in "${ALLOWED_IPS[@]}"; do

            if ! firewall-cmd \
                --permanent \
                --ipset="$IPSET_NAME" \
                --query-entry="$ip" >/dev/null 2>&1; then

                log ERROR "Permanent allow IP missing: $ip"
                failed=1
            fi
        done
    fi

    #
    # Runtime entries
    #
    if ipset_exists_runtime; then

        for ip in "${ALLOWED_IPS[@]}"; do

            if ! firewall-cmd \
                --ipset="$IPSET_NAME" \
                --query-entry="$ip" >/dev/null 2>&1; then

                log ERROR "Runtime allow IP missing: $ip"
                failed=1
            fi
        done
    fi

    #
    # Detect unexpected IPs
    #
    if ipset_exists_permanent; then

        while IFS= read -r ip; do

            [[ -z "$ip" ]] && continue

            if ! ip_is_desired "$ip"; then
                log ERROR "Unexpected IP in allowlist: $ip"
                failed=1
            fi

        done < <(
            firewall-cmd \
                --permanent \
                --ipset="$IPSET_NAME" \
                --get-entries 2>/dev/null
        )
    fi

    #
    # Verify rich rules
    #
    for rule in "${RICH_RULES[@]}"; do

        if ! firewall-cmd \
            --permanent \
            --zone="$ZONE" \
            --query-rich-rule="$rule" >/dev/null 2>&1; then

            log ERROR "Permanent rule missing: $rule"
            failed=1
        fi

        if ! firewall-cmd \
            --zone="$ZONE" \
            --query-rich-rule="$rule" >/dev/null 2>&1; then

            log ERROR "Runtime rule missing: $rule"
            failed=1
        fi
    done

    #
    # Important security check:
    # ports must NOT be globally exposed.
    #
    for portproto in \
        "30303/tcp" \
        "30303/udp" \
        "8544/tcp"
    do
        if firewall-cmd \
            --zone="$ZONE" \
            --query-port="$portproto" >/dev/null 2>&1; then

            log ERROR \
                "SECURITY: $portproto is globally open in zone $ZONE"

            failed=1
        fi
    done

    if [[ $failed -eq 0 ]]; then

        log INFO \
            "VERIFY OK: zone=$ZONE ipset=$IPSET_NAME IPs=${#ALLOWED_IPS[@]} rules=${#RICH_RULES[@]}"

        return 0
    fi

    log ERROR "VERIFY FAILED"
    return 1
}


enable_configuration()
{
    log INFO "Applying firewall configuration..."

    create_ipset
    sync_ipset_entries
    ensure_rich_rules
    reload_firewall

    verify_configuration
}


refresh_configuration()
{
    log INFO "Refreshing firewall configuration..."

    create_ipset
    sync_ipset_entries
    ensure_rich_rules
    reload_firewall

    verify_configuration
}


rebuild_configuration()
{
    log WARNING "Rebuilding managed firewall configuration..."

    #
    # Only remove rules managed by this script.
    #
    remove_rich_rules

    #
    # Reload first so runtime no longer references the ipset.
    #
    reload_firewall

    remove_ipset

    create_ipset
    sync_ipset_entries
    ensure_rich_rules

    reload_firewall

    verify_configuration
}


disable_configuration()
{
    log WARNING "Disabling managed firewall configuration..."

    remove_rich_rules
    reload_firewall

    remove_ipset
    reload_firewall

    log INFO "Managed firewall configuration removed."
}


check_and_repair()
{
    log INFO "Scheduled firewall verification started."

    if verify_configuration; then

        log INFO "Firewall configuration is healthy."
        return 0
    fi

    log WARNING "Firewall configuration drift detected. Repairing..."

    refresh_configuration

    if verify_configuration; then
        log INFO "Firewall configuration repaired successfully."
        return 0
    fi

    log ERROR "Firewall configuration repair failed."
    return 1
}


show_status()
{
    echo
    echo "============================================================"
    echo "Firewalld status"
    echo "============================================================"

    systemctl --no-pager --full status firewalld || true

    echo
    echo "============================================================"
    echo "Active zones"
    echo "============================================================"

    firewall-cmd --get-active-zones

    echo
    echo "============================================================"
    echo "Zone: $ZONE"
    echo "============================================================"

    firewall-cmd --zone="$ZONE" --list-all

    echo
    echo "============================================================"
    echo "IP set: $IPSET_NAME"
    echo "============================================================"

    if ipset_exists_runtime; then
        firewall-cmd \
            --ipset="$IPSET_NAME" \
            --get-entries |
            sort
    else
        echo "IP set not found."
    fi

    echo
}


usage()
{
    cat <<EOF

Usage:

  $0 enable
  $0 refresh
  $0 rebuild
  $0 verify
  $0 check
  $0 disable
  $0 status

Commands:

  enable
      Create IP set, add IPs and rich rules.

  refresh
      Synchronize configured IP list.
      Add missing IPs and remove stale IPs.

  rebuild
      Remove ONLY the rules/IP set managed by this script
      and rebuild them.

  verify
      Check permanent and runtime configuration.
      No configuration changes.

  check
      Designed for cron.
      Verify configuration and automatically repair drift.

  disable
      Remove ONLY firewall objects managed by this script.

  status
      Display current firewalld configuration.

EOF
}


# ============================================================
# MAIN
# ============================================================

require_root
check_commands
check_firewalld
check_zone
acquire_lock

ACTION="${1:-}"

case "$ACTION" in

    enable)
        enable_configuration
        ;;

    refresh)
        refresh_configuration
        ;;

    rebuild)
        rebuild_configuration
        ;;

    verify)
        verify_configuration
        ;;

    check)
        check_and_repair
        ;;

    disable)
        disable_configuration
        ;;

    status)
        show_status
        ;;

    *)
        usage
        exit 1
        ;;
esac

exit $?
