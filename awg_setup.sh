#!/bin/sh

# --- SCRIPT SETUP ---
# Change to the script's own directory to ensure paths are correct
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
cd "$SCRIPT_DIR" || exit 1

# --- CONFIGURATION ---
# Define configuration file paths
config_file="amnezia_for_awg.conf"
interface_config="awg0.conf"

# Check if the main configuration file exists
if [ ! -f "$config_file" ]; then
    echo "Error: Configuration file '$config_file' not found."
    exit 1
fi

# Extract client address and DNS from the configuration file
# Note: We only use the first DNS server listed if multiple are present.
address=$(awk -F' = ' '/^Address/ {print $2}' "$config_file")
dns=$(awk -F' = ' '/^DNS/ {print $2}' "$config_file" | cut -d',' -f1)

echo "AmneziaWG client address: $address"
echo "Primary DNS for VPN: $dns"

# Create the specific interface config from the main config if it doesn't exist
if [ -f "$interface_config" ]; then
    echo "$interface_config already exists."
else
    # This creates awg0.conf by stripping Address and DNS lines from the main config
    awk '!/^Address/ && !/^DNS/' "$config_file" > "$interface_config"
    echo "$interface_config created."
fi

# --- DEPENDENCY DOWNLOAD ---
# Download AmneziaWG binaries if they are not present
if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
    echo "Downloading AmneziaWG binaries..."
    curl -L -o awg.tar.gz https://github.com/nikita-emelianov/awg-be7000/raw/main/awg.tar.gz
    tar -xzvf awg.tar.gz
    chmod +x amneziawg-go awg
    rm awg.tar.gz
fi

# --- HELPER SCRIPT DOWNLOADS ---
# Download helper scripts for cleanup and monitoring if they are not present
if [ ! -f "awg_clear_firewall_settings.sh" ]; then
    curl -L -o awg_clear_firewall_settings.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_clear_firewall_settings.sh && chmod +x awg_clear_firewall_settings.sh
fi
if [ ! -f "awg_watchdog.sh" ]; then
    curl -L -o awg_watchdog.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_watchdog.sh && chmod +x awg_watchdog.sh
fi

# --- INTERFACE SETUP AND DAEMON MANAGEMENT ---
echo "Ensuring a clean state for awg0 interface and amneziawg-go daemon..."
# Kill any existing amneziawg-go process
PID=$(ps | grep amneziawg-go | grep -v grep | awk '{print $1}')
[ -n "$PID" ] && kill "$PID" 2>/dev/null && sleep 1

# Delete the awg0 interface if it exists
if ip link show awg0 > /dev/null 2>&1; then
    ip link set dev awg0 down 2>/dev/null
    ip link del dev awg0 2>/dev/null
    sleep 1
fi

echo "Starting amneziawg-go daemon in the background..."
/data/usr/app/awg/amneziawg-go awg0 &
sleep 2 # Wait for the interface to be created

# Verify interface creation before proceeding
if ! ip link show awg0 > /dev/null 2>&1; then
    echo "Error: awg0 interface was not created. Aborting setup."
    exit 1
fi

echo "Applying AmneziaWG configuration and setting IP address."
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip a add "$address" dev awg0
ip l set up awg0

# --- ROUTING RULES ---
# This section uses Policy-Based Routing to send all traffic from the guest network (192.168.33.0/24)
# through the VPN tunnel (awg0 interface).

# Clean up old route to prevent conflicts
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null

# Ensure guest subnet is correctly associated with the guest bridge
ip route add 192.168.33.0/24 dev br-guest table main

# Create a default route in a separate routing table (200) that points to the VPN interface
ip route add default dev awg0 table 200

# Create a rule to allow local DNS requests on the router itself to use the main table (for router services)
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100

# Create the main rule: all other traffic from the guest subnet must use our VPN routing table (200)
ip rule add from 192.168.33.0/24 table 200 pref 200

# --- FIREWALL RULES ---
echo "Flushing old iptables rules to ensure a clean slate..."
iptables -F FORWARD
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -t mangle -F FORWARD
ip6tables -F FORWARD

# --- [MODIFIED] MSS CLAMPING RULE ---
# This is the most critical fix for mobile device connectivity.
# It prevents packet loss (PMTUD black holes) by dynamically adjusting the Maximum Segment Size (MSS)
# of TCP packets to fit within the VPN's smaller Maximum Transmission Unit (MTU).
# '--clamp-mss-to-pmtu' is superior to a fixed value as it adapts automatically.
echo "Applying dynamic TCP MSS clamping for VPN stability..."
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# --- [MODIFIED] IPv6 HANDLING ---
# Explicitly REJECT IPv6 traffic from the guest network.
# This forces IPv6-first devices (like mobile phones) to immediately fall back to IPv4,
# preventing long connection timeouts caused by a broken IPv6 path over the VPN.
# 'REJECT' is better than 'DROP' as it provides instant feedback to the client.
echo "Rejecting IPv6 traffic from guest network to enforce IPv4 fallback..."
ip6tables -A FORWARD -i br-guest -j REJECT

# --- [MODIFIED] DNS POLICY ENFORCEMENT ---
# Block DNS-over-TLS (DoT) on port 853.
# This prevents Android/iOS "Private DNS" features from bypassing our VPN's DNS settings.
echo "Blocking DNS-over-TLS (Port 853) to prevent DNS bypass..."
iptables -A FORWARD -i br-guest -p tcp --dport 853 -j REJECT
iptables -A FORWARD -i br-guest -p udp --dport 853 -j REJECT

# --- [NEW] BLOCK PUBLIC DNS & DNS-over-HTTPS (DoH) ---
# This is a critical step to force all clients, especially mobile browsers that prefer DoH,
# to use the VPN's intended DNS resolver. We block known public DNS servers on all ports.
# This prevents browsers from bypassing our DNS hijacking rules by using DoH on port 443.
echo "Blocking common public DNS/DoH providers to enforce VPN DNS..."
# Cloudflare
iptables -A FORWARD -i br-guest -d 1.1.1.1 -j REJECT
iptables -A FORWARD -i br-guest -d 1.0.0.1 -j REJECT
# Google
iptables -A FORWARD -i br-guest -d 8.8.8.8 -j REJECT
iptables -A FORWARD -i br-guest -d 8.8.4.4 -j REJECT
# Quad9
iptables -A FORWARD -i br-guest -d 9.9.9.9 -j REJECT
iptables -A FORWARD -i br-guest -d 149.112.112.112 -j REJECT
# OpenDNS
iptables -A FORWARD -i br-guest -d 208.67.222.222 -j REJECT
iptables -A FORWARD -i br-guest -d 208.67.220.220 -j REJECT

# --- GUEST NETWORK FIREWALL CONFIGURATION ---
echo "Configuring firewall rules for guest network..."
# Allow local DNS requests to the router itself (for clients that use the router as DNS forwarder)
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT

# Allow traffic to flow between the guest network and the VPN tunnel
iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o br-guest -j ACCEPT

# --- NETWORK ADDRESS TRANSLATION (NAT) ---
# Hijack all standard DNS requests (port 53) from the guest network and redirect them to the VPN's DNS server.
# This ensures all clients use the VPN's DNS, regardless of their local configuration.
iptables -t nat -A PREROUTING -i br-guest -p udp --dport 53 -j DNAT --to-destination "${dns}:53"
iptables -t nat -A PREROUTING -i br-guest -p tcp --dport 53 -j DNAT --to-destination "${dns}:53"

# Apply MASQUERADE (NAT) for all other traffic from the guest network leaving through the VPN tunnel.
# This makes all guest traffic appear to come from the VPN server's IP address.
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# --- UCI & SERVICE SETUP (OpenWrt Specific) ---
# This section integrates the 'awg0' interface into OpenWrt's firewall system.
echo "Integrating awg0 interface into OpenWrt firewall..."
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='ACCEPT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='ACCEPT'

# Add forwarding rules between the 'guest' and 'awg' firewall zones if they don't exist
if ! uci show firewall | grep -qE "src='awg'|dest='awg'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='guest'
    uci set firewall.@forwarding[-1].dest='awg'
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='awg'
    uci set firewall.@forwarding[-1].dest='guest'
fi
uci commit firewall

# --- FINALIZATION ---
echo "Restarting firewall and enabling IP forwarding..."
ip route flush cache
/etc/init.d/firewall reload
echo 1 > /proc/sys/net/ipv4/ip_forward

# --- CRON JOB ---
# Ensure the watchdog script runs every minute to maintain the connection
CRON_COMMAND="* * * * * sh /data/usr/app/awg/awg_watchdog.sh > /dev/null 2>&1"
if ! crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON_COMMAND") | crontab -
fi

echo "Setup complete. Guest network traffic is now routed through AmneziaWG."
