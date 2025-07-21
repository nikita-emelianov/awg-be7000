#!/bin/sh

# Automates the setup and configuration of AWG for a guest network. The script is idempotent and can be re-run safely.

set -e

# --- Configuration and Constants ---
# All user-configurable variables are placed here for easy access.
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
MAIN_CONFIG_FILE="amnezia_for_awg.conf"
INTERFACE_CONFIG_FILE="awg0.conf"

# Network Settings
GUEST_NETWORK="192.168.33.0/24"
GUEST_BRIDGE="br-guest"
GUEST_ROUTER_IP="192.168.33.1"
VPN_INTERFACE="awg0"
VPN_ROUTING_TABLE="200"

# URLs for Dependencies
AWG_ARCHIVE_URL="https://github.com/nikita-emelianov/awg-be7000/raw/main/awg.tar.gz"
CLEAR_FW_SCRIPT_URL="https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_clear_firewall_settings.sh"
WATCHDOG_SCRIPT_URL="https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_watchdog.sh"

# --- Utility Functions ---

log() {
    echo "INFO: $1"
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

# Download a file from a URL if it doesn't already exist.
# Arguments: $1: URL, $2: Destination file path
download_if_missing() {
    local url="$1"
    local dest_file="$2"
    if [ ! -f "$dest_file" ]; then
        log "Downloading '$dest_file'..."
        if ! curl -fsSL -o "$dest_file" "$url"; then
            die "Failed to download from $url"
        fi
        log "'$dest_file' downloaded successfully."
    else
        log "'$dest_file' already exists."
    fi
}

# --- Core Logic ---

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root."
    fi
}

setup_dependencies() {
    log "Checking for dependencies..."

    if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
        log "AmneziaWG binaries not found."
        download_if_missing "$AWG_ARCHIVE_URL" "awg.tar.gz"
        if ! tar -xzvf awg.tar.gz; then
            die "Failed to extract awg.tar.gz"
        fi
        chmod +x amneziawg-go awg
        rm awg.tar.gz
        log "Binaries unpacked and made executable."
    else
        log "AmneziaWG binaries already exist."
    fi

    download_if_missing "$CLEAR_FW_SCRIPT_URL" "awg_clear_firewall_settings.sh"
    chmod +x "awg_clear_firewall_settings.sh"

    download_if_missing "$WATCHDOG_SCRIPT_URL" "awg_watchdog.sh"
    chmod +x "awg_watchdog.sh"
}

create_interface_config() {
    log "Parsing main configuration..."
    [ -f "$MAIN_CONFIG_FILE" ] || die "Main configuration file '$MAIN_CONFIG_FILE' not found."

    export ADDRESS
    ADDRESS=$(awk -F' = ' '/^Address/ {print $2}' "$MAIN_CONFIG_FILE")
    
    export FIRST_DNS
    DNS_SERVERS=$(awk -F' = ' '/^DNS/ {print $2}' "$MAIN_CONFIG_FILE")
    FIRST_DNS=$(echo "$DNS_SERVERS" | cut -d',' -f1)

    [ -n "$ADDRESS" ] || die "Could not parse Address from '$MAIN_CONFIG_FILE'."
    [ -n "$FIRST_DNS" ] || die "Could not parse DNS from '$MAIN_CONFIG_FILE'."

    log "AmneziaWG client address: $ADDRESS"
    log "Primary DNS to be used: $FIRST_DNS"

    if [ ! -f "$INTERFACE_CONFIG_FILE" ]; then
        log "Creating '$INTERFACE_CONFIG_FILE'..."
        awk '!/^Address/ && !/^DNS/' "$MAIN_CONFIG_FILE" > "$INTERFACE_CONFIG_FILE"
    else
        log "'$INTERFACE_CONFIG_FILE' already exists."
    fi
}

reset_and_start_interface() {
    log "Resetting AmneziaWG interface and daemon..."

    # Stop any running amneziawg-go daemon. pkill is more direct.
    if pkill -f amneziawg-go; then
        log "Stopped existing amneziawg-go daemon."
        sleep 1
    fi

    # Delete the awg0 interface if it exists. Ignore errors if it doesn't.
    if ip link show "$VPN_INTERFACE" > /dev/null 2>&1; then
        log "Deleting existing '$VPN_INTERFACE' interface."
        ip link set dev "$VPN_INTERFACE" down 2>/dev/null || true
        ip link del dev "$VPN_INTERFACE" 2>/dev/null || true
        sleep 1
    fi

    log "Starting amneziawg-go daemon in the background..."
    ./amneziawg-go "$VPN_INTERFACE" &
    # Give the daemon time to initialize and create the interface.
    sleep 2

    ip link show "$VPN_INTERFACE" > /dev/null 2>&1 || die "Daemon failed to create '$VPN_INTERFACE'."
    log "'$VPN_INTERFACE' interface created successfully."

    log "Applying configuration to '$VPN_INTERFACE'..."
    ./awg setconf "$VPN_INTERFACE" "$INTERFACE_CONFIG_FILE"
    ip addr add "$ADDRESS" dev "$VPN_INTERFACE"
    ip link set up dev "$VPN_INTERFACE"
    log "Interface '$VPN_INTERFACE' is up and configured."
}

setup_routing_and_firewall() {
    log "Configuring routing and firewall rules..."

    # Run the cleanup script to remove old iptables rules for an idempotent setup.
    if [ -f "./awg_clear_firewall_settings.sh" ]; then
        log "Running firewall cleanup script..."
        sh ./awg_clear_firewall_settings.sh
    else
        log "Firewall cleanup script not found. Manual cleanup may be needed on re-runs."
    fi

    # Clean up old routes and rules to prevent errors on re-run.
    ip route del "$GUEST_NETWORK" dev "$GUEST_BRIDGE" 2>/dev/null || true
    ip rule del from "$GUEST_NETWORK" table "$VPN_ROUTING_TABLE" 2>/dev/null || true
    ip rule del from "$GUEST_NETWORK" to "$GUEST_ROUTER_IP" dport 53 2>/dev/null || true

    log "Setting up policy-based routing for guest network..."
    ip route add default dev "$VPN_INTERFACE" table "$VPN_ROUTING_TABLE"
    ip rule add from "$GUEST_NETWORK" to "$GUEST_ROUTER_IP" dport 53 table main pref 100
    ip rule add from "$GUEST_NETWORK" table "$VPN_ROUTING_TABLE" pref 200

    log "Setting up iptables rules for guest network..."
    # Allow guest devices to reach the router for local DNS resolution.
    iptables -A FORWARD -i "$GUEST_BRIDGE" -d "$GUEST_ROUTER_IP" -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$GUEST_BRIDGE" -d "$GUEST_ROUTER_IP" -p udp --dport 53 -j ACCEPT

    # Allow traffic between the guest network and the VPN interface.
    iptables -A FORWARD -i "$GUEST_BRIDGE" -o "$VPN_INTERFACE" -j ACCEPT
    iptables -A FORWARD -i "$VPN_INTERFACE" -o "$GUEST_BRIDGE" -j ACCEPT

    # NAT DNS requests from guest network to the VPN's DNS server.
    iptables -t nat -A PREROUTING -s "$GUEST_NETWORK" -p udp --dport 53 -j DNAT --to-destination "${FIRST_DNS}:53"
    iptables -t nat -A PREROUTING -s "$GUEST_NETWORK" -p tcp --dport 53 -j DNAT --to-destination "${FIRST_DNS}:53"

    # NAT all other guest network traffic through the VPN interface.
    iptables -t nat -A POSTROUTING -s "$GUEST_NETWORK" -o "$VPN_INTERFACE" -j MASQUERADE

    log "Configuring UCI firewall for '$VPN_INTERFACE' zone..."
    uci set firewall.awg=zone
    uci set firewall.awg.name='awg'
    uci set firewall.awg.network="$VPN_INTERFACE"
    uci set firewall.awg.input='ACCEPT'
    uci set firewall.awg.output='ACCEPT'
    uci set firewall.awg.forward='ACCEPT'

    # Add forwarding rules between guest and awg zones if they don't exist.
    if ! uci show firewall | grep -q "src='guest' && dest='awg'"; then
        uci add firewall forwarding >/dev/null
        uci set firewall.@forwarding[-1].src='guest'
        uci set firewall.@forwarding[-1].dest='awg'
    fi
    if ! uci show firewall | grep -q "src='awg' && dest='guest'"; then
        uci add firewall forwarding >/dev/null
        uci set firewall.@forwarding[-1].src='awg'
        uci set firewall.@forwarding[-1].dest='guest'
    fi
    uci commit firewall

    log "Reloading firewall and flushing route cache..."
    ip route flush cache
    /etc/init.d/firewall reload

    log "Enabling kernel IP forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
}

setup_cron() {
    log "Setting up watchdog cron job..."
    local cron_script_path="$SCRIPT_DIR/awg_watchdog.sh"
    local cron_command="* * * * * sh $cron_script_path > /dev/null 2>&1"
    local cron_identifier="# AmneziaWG Watchdog"

    # Atomically update the crontab to prevent duplicate entries on re-runs.
    (crontab -l 2>/dev/null | grep -vF "$cron_identifier" | grep -vF "awg_watchdog.sh"; \
     echo "$cron_identifier"; \
     echo "$cron_command") | crontab -

    log "Cron job for watchdog has been configured."
}

# --- Main Execution ---

main() {
    # Change to the script's own directory to ensure relative paths work.
    cd "$SCRIPT_DIR" || die "Could not change to script directory '$SCRIPT_DIR'"

    check_root
    log "--- Starting AmneziaWG Setup Script ---"

    setup_dependencies
    create_interface_config
    reset_and_start_interface
    setup_routing_and_firewall
    setup_cron

    log "--- Setup complete. ---"
}

main "$@"
