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

# --- ROUTING RULES ---
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
ip rule add from 192.168.33.0/24 table 200 pref 200

# --- FIREWALL RULES ---

# Flush existing rules to prevent duplicates on re-run
echo "Flushing old firewall rules..."
iptables -F FORWARD
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -t mangle -F FORWARD # <<< CHANGE: Flush mangle table
ip6tables -F FORWARD          # <<< CHANGE: Flush ip6tables FORWARD chain

# <<< CHANGE: Block all IPv6 traffic on the guest network to prevent leaks >>>
echo "Blocking IPv6 on guest network..."
ip6tables -A FORWARD -i br-guest -j DROP
ip6tables -A FORWARD -o br-guest -j DROP

# Set up firewall for local DNS requests on the router itself
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT

# Allow traffic between guest network and the VPN tunnel
iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o br-guest -j ACCEPT

# Set up NAT for DNS requests from guest network (redirect to VPN's DNS)
iptables -t nat -A PREROUTING -p udp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination "${dns}:53"
iptables -t nat -A PREROUTING -p tcp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination "${dns}:53"

# Set up NAT for all other guest network traffic
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# <<< CHANGE: Clamp TCP MSS to fix mobile connectivity issues (MTU) >>>
echo "Clamping TCP MSS to prevent MTU issues..."
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg0 -j TCPMSS --set-mss 1432

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
