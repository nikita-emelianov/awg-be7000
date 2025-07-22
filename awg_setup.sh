#!/bin/sh

# Change to the script's own directory to ensure all relative paths work correctly.
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
echo "DNS for redirection: $dns"

# Create awg0.conf if it doesn't exist, excluding Address and DNS lines
if [ -f "$interface_config" ]; then
    echo "$interface_config already exists."
else
    awk '!/^Address/ && !/^DNS/' "$config_file" > "$interface_config"
    echo "$interface_config created."
fi

# --- DEPENDENCY AND HELPER SCRIPT DOWNLOAD ---
if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
    echo "AmneziaWG binaries not found. Downloading..."
    curl -L -o awg.tar.gz https://github.com/nikita-emelianov/awg-be7000/raw/main/awg.tar.gz
    tar -xzvf awg.tar.gz
    chmod +x amneziawg-go awg
    rm awg.tar.gz
fi
if [ ! -f "awg_watchdog.sh" ]; then
    curl -L -o awg_watchdog.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_watchdog.sh && chmod +x awg_watchdog.sh
fi

# --- INTERFACE SETUP AND DAEMON MANAGEMENT SECTION ---
echo "Ensuring a clean state and setting up awg0 interface..."
PID=$(ps w | grep amneziawg-go | grep -v grep | awk '{print $1}')
[ -n "$PID" ] && kill "$PID" 2>/dev/null && sleep 1
ip link del dev awg0 2>/dev/null && sleep 1

/data/usr/app/awg/amneziawg-go awg0 &
sleep 2
if ! ip link show awg0 > /dev/null 2>&1; then
    echo "Error: awg0 interface was not created. Aborting."
    exit 1
fi

/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip a add "$address" dev awg0
ip l set up awg0
echo "awg0 interface is up."

# --- ROUTING RULES ---
echo "Configuring policy routing for the guest network..."
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
# Keep the rule to allow guest clients to talk to the router for DNS
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
# Route all other guest traffic to the VPN table
ip rule add from 192.168.33.0/24 table 200 pref 200

# --- NATIVE FIREWALL CONFIGURATION (UCI) ---
echo "Configuring firewall using the native UCI system..."

# Block IPv6 on the guest interface to prevent leaks
ip6tables -F FORWARD
ip6tables -A FORWARD -i br-guest -j DROP
ip6tables -A FORWARD -o br-guest -j DROP

# Create a firewall zone for the VPN interface
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='REJECT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='REJECT'
uci set firewall.awg.masq='1'      # Let the firewall handle NAT/Masquerading
uci set firewall.awg.mtu_fix='1'   # Let the firewall handle MTU/MSS clamping

# Create a forwarding rule to allow traffic FROM the 'guest' zone TO the new 'awg' zone
uci set firewall.guest_to_awg=forwarding
uci set firewall.guest_to_awg.src='guest'
uci set firewall.guest_to_awg.dest='awg'

# Create a DNS redirection rule for the guest zone using the native firewall
# This redirects any DNS request from guests to the DNS server specified in your config
uci -q delete firewall.redirect_guest_dns
uci set firewall.redirect_guest_dns=redirect
uci set firewall.redirect_guest_dns.name='Redirect-Guest-DNS-to-VPN'
uci set firewall.redirect_guest_dns.target='DNAT'
uci set firewall.redirect_guest_dns.src='guest'
uci set firewall.redirect_guest_dns.src_dport='53'
uci set firewall.redirect_guest_dns.proto='tcp udp'
uci set firewall.redirect_guest_dns.dest_ip="${dns}"
uci set firewall.redirect_guest_dns.dest_port='53'

# Apply all firewall changes by reloading the firewall
uci commit firewall
echo "Restarting firewall to apply changes..."
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

echo "✅ Setup complete. The guest network should now be fully routed through the VPN."
