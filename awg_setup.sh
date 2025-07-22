#!/bin/sh

# Change to the script's own directory to ensure all relative paths work correctly.
# This is critical for running the script via cron.
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
cd "$SCRIPT_DIR" || exit 1

# Define configuration file paths
config_file="amnezia_for_awg.conf"
interface_config="awg0.conf"

# Check if the main configuration file exists
if [ ! -f "$config_file" ]; then
    echo "Error: Configuration file '$config_file' not found."
    exit 1
fi

# Extract client address and DNS from the configuration file
address=$(awk -F' = ' '/^Address/ {print $2}' "$config_file")
dns=$(awk -F' = ' '/^DNS/ {print $2}' "$config_file")
# Take only the first DNS server if multiple are listed
dns=$(echo "$dns" | cut -d',' -f1)

echo "AmneziaWG client address: $address"
echo "DNS: $dns"

# Create awg0.conf if it doesn't exist, excluding Address and DNS lines
if [ -f "$interface_config" ]; then
    echo "$interface_config already exists."
else
    awk '!/^Address/ && !/^DNS/' "$config_file" > "$interface_config"
    echo "$interface_config created."
fi

# --- DEPENDENCY DOWNLOAD ---
if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
    echo "AmneziaWG binaries not found. Downloading..."
    curl -L -o awg.tar.gz https://github.com/nikita-emelianov/awg-be7000/raw/main/awg.tar.gz
    tar -xzvf awg.tar.gz
    chmod +x amneziawg-go awg
    rm awg.tar.gz
    echo "Archive downloaded and unpacked."
else
    echo "AmneziaWG binaries exist, proceeding."
fi

# --- HELPER SCRIPT DOWNLOADS (SEPARATED) ---
if [ ! -f "awg_clear_firewall_settings.sh" ]; then
    curl -L -o awg_clear_firewall_settings.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_clear_firewall_settings.sh && chmod +x awg_clear_firewall_settings.sh
fi
if [ ! -f "awg_watchdog.sh" ]; then
    curl -L -o awg_watchdog.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_watchdog.sh && chmod +x awg_watchdog.sh
fi

# --- INTERFACE SETUP AND DAEMON MANAGEMENT SECTION ---
echo "Ensuring a clean state for awg0 interface and amneziawg-go daemon..."
PID=$(ps | grep amneziawg-go | grep -v grep | awk '{print $1}')
if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null
    sleep 1
fi
if ip link show awg0 > /dev/null 2>&1; then
    ip link set dev awg0 down 2>/dev/null
    ip link del dev awg0 2>/dev/null
    sleep 1
fi
echo "Starting amneziawg-go daemon in the background..."
/data/usr/app/awg/amneziawg-go awg0 &
sleep 2
if ! ip link show awg0 > /dev/null 2>&1; then
    echo "Error: awg0 interface was not created by amneziawg-go daemon. Aborting setup."
    exit 1
fi
echo "awg0 interface successfully created by amneziawg-go daemon."
echo "Applying AmneziaWG configuration and IP address."
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip a add "$address" dev awg0
ip l set up awg0

# --- PATCH: Set lower MTU for compatibility with Android ---
ip link set dev awg0 mtu 1280

# --- ROUTING RULES ---
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
ip rule add from 192.168.33.0/24 table 200 pref 200

# --- FIREWALL RULES (REVISED STRATEGY) ---

# --- FIREWALL RULE FLUSHING ---
echo "Flushing old iptables & ip6tables rules..."
iptables -F FORWARD
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -t mangle -F FORWARD
iptables -t mangle -F POSTROUTING
ip6tables -F FORWARD 2>/dev/null

# --- !! NEW: EXPLICIT FIREWALL POLICY & LOGGING !! ---
# We are now using a "default-deny" policy. All traffic is blocked unless
# explicitly allowed by a rule. This is more secure and reliable.
echo "Setting up restrictive firewall policy..."
iptables -P FORWARD DROP

# Create a custom chain for logging dropped packets for easier debugging
iptables -N LOG_DROP 2>/dev/null
iptables -F LOG_DROP
iptables -A LOG_DROP -j LOG --log-prefix "Dropped by VPN script: " --log-level 7
iptables -A LOG_DROP -j DROP

# Allow returning traffic for established connections
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow new connections from the guest network to go out the VPN tunnel
iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT

# --- !! NEW: ROBUST TCP MSS CLAMPING !! ---
# This rule is more robust for preventing packet fragmentation issues.
# It clamps the MSS to the path MTU, which is a more dynamic approach.
echo "Applying robust TCP MSS clamping for VPN interface..."
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg0 -j TCPMSS --clamp-to-pmtu

# --- !! NEW: EXPLICIT IPV6 BLOCKING !! ---
# Forcefully reject IPv6 traffic from the guest network to prevent connection hangs.
echo "Blocking IPv6 on guest network to prevent VPN hangs..."
ip6tables -P FORWARD DROP 2>/dev/null
ip6tables -A FORWARD -i br-guest -j REJECT --reject-with adm-prohibited 2>/dev/null

# --- NAT & DNS RULES (UNCHANGED LOGIC) ---
# Set up NAT for DNS requests from guest network (redirect to VPN's DNS)
iptables -t nat -A PREROUTING -p udp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination "${dns}:53"
iptables -t nat -A PREROUTING -p tcp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination "${dns}:53"

# --- PATCH: Force redirect DNS requests to 8.8.8.8 to working VPN DNS ---
iptables -t nat -A PREROUTING -s 192.168.33.0/24 -d 8.8.8.8 -p udp --dport 53 -j DNAT --to-destination "${dns}:53"
iptables -t nat -A PREROUTING -s 192.168.33.0/24 -d 8.8.8.8 -p tcp --dport 53 -j DNAT --to-destination "${dns}:53"

# Set up NAT for all other guest network traffic
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# Finally, log and drop any forwarded packet that wasn't explicitly allowed.
iptables -A FORWARD -j LOG_DROP

# --- UCI & SERVICE SETUP ---
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='ACCEPT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='ACCEPT'
if ! uci show firewall | grep -qE "src='awg'|dest='awg'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='guest'
    uci set firewall.@forwarding[-1].dest='awg'
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='awg'
    uci set firewall.@forwarding[-1].dest='guest'
fi
uci commit firewall

echo "Restarting firewall..."
ip route flush cache
/etc/init.d/firewall reload
echo 1 > /proc/sys/net/ipv4/ip_forward

# --- CRON JOB ---
CRON_COMMAND="* * * * * sh /data/usr/app/awg/awg_watchdog.sh > /dev/null 2>&1"
if ! crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh"; then
    echo "Adding cron job for watchdog script..."
    (crontab -l 2>/dev/null; echo "$CRON_COMMAND") | crontab -
    echo "Cron job added successfully."
else
    echo "Cron job for watchdog script already exists."
fi

echo "Setup complete!"
echo ""
echo "DIAGNOSTIC INFO: If you still have issues, check the system log for dropped packets with the command: dmesg | grep 'Dropped by VPN script'"
