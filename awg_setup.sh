#!/bin/sh

# Change to the script's own directory
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
cd "$SCRIPT_DIR" || exit 1

# --- CONFIGURATION & VARIABLES ---
config_file="amnezia_for_awg.conf"
interface_config="awg0.conf"

# Dynamically find the guest network's IPv6 prefix (for br-guest)
echo "Detecting guest network IPv6 prefix..."
GUEST_IPV6_PREFIX=$(ip -6 addr show dev br-guest | grep 'scope global' | awk '{print $2}' | head -n 1)

if [ -z "$GUEST_IPV6_PREFIX" ]; then
    echo "Error: Could not automatically find a global IPv6 prefix for the br-guest interface."
    echo "Please ensure the guest network has a valid IPv6 ULA or GUA address."
    exit 1
fi

echo "Successfully found guest IPv6 prefix: $GUEST_IPV6_PREFIX"

# Check if the main configuration file exists
if [ ! -f "$config_file" ]; then
    echo "Error: Configuration file '$config_file' not found."
    exit 1
fi

# Extract client addresses and DNS from the configuration file
# Separate IPv4 and IPv6 addresses and DNS servers
address_v4=$(awk -F' = ' '/^Address/ {print $2}' "$config_file" | cut -d',' -f1)
address_v6=$(awk -F' = ' '/^Address/ {print $2}' "$config_file" | cut -d',' -f2)
dns_v4=$(awk -F' = ' '/^DNS/ {print $2}' "$config_file" | cut -d',' -f1)
dns_v6=$(awk -F' = ' '/^DNS/ {print $2}' "$config_file" | cut -d',' -f2)
[ -z "$dns_v6" ] && dns_v6=$dns_v4 # Fallback to v4 DNS if v6 DNS is not set

echo "AmneziaWG IPv4 client address: $address_v4"
[ -n "$address_v6" ] && echo "AmneziaWG IPv6 client address: $address_v6"
echo "DNSv4: $dns_v4"
[ -n "$dns_v6" ] && echo "DNSv6: $dns_v6"

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

# --- HELPER SCRIPT DOWNLOADS ---
# (No changes in this section)
if [ ! -f "awg_clear_firewall_settings.sh" ]; then
    curl -L -o awg_clear_firewall_settings.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_clear_firewall_settings.sh && chmod +x awg_clear_firewall_settings.sh
fi
if [ ! -f "awg_watchdog.sh" ]; then
    curl -L -o awg_watchdog.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_watchdog.sh && chmod +x awg_watchdog.sh
fi


# --- INTERFACE SETUP AND DAEMON MANAGEMENT SECTION ---
echo "Ensuring a clean state for awg0 interface and amneziawg-go daemon..."

# 1. Stop any running amneziawg-go processes
PID=$(ps | grep amneziawg-go | grep -v grep | awk '{print $1}')
if [ -n "$PID" ]; then
    echo "Found existing amneziawg-go process (PID: $PID). Killing it..."
    kill "$PID" 2>/dev/null
    sleep 1
fi

# 2. Delete the awg0 interface if it exists
if ip link show awg0 > /dev/null 2>&1; then
    echo "Existing awg0 interface found. Bringing it down and deleting it..."
    ip link set dev awg0 down 2>/dev/null
    ip link del dev awg0 2>/dev/null
    sleep 1
fi

# 3. Start the amneziawg-go daemon
echo "Starting amneziawg-go daemon in the background..."
/data/usr/app/awg/amneziawg-go awg0 &
sleep 2

# 4. Verify awg0 is now present
if ! ip link show awg0 > /dev/null 2>&1; then
    echo "Error: awg0 interface was not created. Aborting setup."
    exit 1
fi
echo "awg0 interface successfully created."

# 5. Apply the configuration and IPs
echo "Applying AmneziaWG configuration and IP addresses."
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip a add "$address_v4" dev awg0
if [ -n "$address_v6" ]; then
    ip -6 a add "$address_v6" dev awg0
fi
ip l set up awg0

# --- ROUTING RULES ---
# Delete existing guest network routes to prevent duplicates
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null
ip -6 route del "$GUEST_IPV6_PREFIX" dev br-guest 2>/dev/null

# Add new guest network routes
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
ip rule add from 192.168.33.0/24 table 200 pref 200
ip -6 route add "$GUEST_IPV6_PREFIX" dev br-guest table main
ip -6 route add default dev awg0 table 200
ip -6 rule add from "$GUEST_IPV6_PREFIX" table 200 pref 200

# --- FIREWALL RULES (iptables & ip6tables) ---
# IPv4 Firewall
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o br-guest -j ACCEPT
# IPv4 NAT
iptables -t nat -A PREROUTING -p udp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination "${dns_v4}:53"
iptables -t nat -A PREROUTING -p tcp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination "${dns_v4}:53"
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# IPv6 Firewall
ip6tables -A FORWARD -i br-guest -o awg0 -j ACCEPT
ip6tables -A FORWARD -i awg0 -o br-guest -j ACCEPT
# IPv6 NAT
if [ -n "$dns_v6" ]; then
    ip6tables -t nat -A PREROUTING -p udp -s "$GUEST_IPV6_PREFIX" --dport 53 -j DNAT --to-destination "[${dns_v6}]:53"
    ip6tables -t nat -A PREROUTING -p tcp -s "$GUEST_IPV6_PREFIX" --dport 53 -j DNAT --to-destination "[${dns_v6}]:53"
fi
ip6tables -t nat -A POSTROUTING -s "$GUEST_IPV6_PREFIX" -o awg0 -j MASQUERADE

# --- FIREWALL (UCI) ---
# (No changes in this section, it should handle both IPv4 and IPv6)
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

# --- FINAL KERNEL & SERVICE SETUP ---
# Clear routes cache and restart firewall
echo "Restarting firewall..."
ip route flush cache
/etc/init.d/firewall reload

# Turn IP-forwarding on for BOTH protocols
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

# --- CRON JOB ---
# (No changes in this section)
CRON_COMMAND="* * * * * sh /data/usr/app/awg/awg_watchdog.sh > /dev/null 2>&1"
if ! crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh"; then
    echo "Adding cron job for watchdog script..."
    (crontab -l 2>/dev/null; echo "$CRON_COMMAND") | crontab -
    echo "Cron job added successfully."
else
    echo "Cron job for watchdog script already exists."
fi

echo "Setup complete. IPv6 should now be working."
