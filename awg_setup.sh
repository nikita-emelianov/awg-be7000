#!/bin/sh

# --- CONFIGURATION AND INITIALIZATION ---
config_file="amnezia_for_awg.conf"
interface_config="awg0.conf"

if [ ! -f "$config_file" ]; then
    echo "Error: Configuration file '$config_file' not found."
    exit 1
fi

address=$(awk -F' = ' '/^Address/ {print $2}' "$config_file")
dns=$(awk -F' = ' '/^DNS/ {print $2}' "$config_file" | cut -d',' -f1)

echo "AmneziaWG client address: $address"
echo "VPN DNS Server: $dns"

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
    echo "Binaries downloaded and unpacked."
else
    echo "AmneziaWG binaries exist."
fi

# --- HELPER SCRIPT DOWNLOADS (SEPARATED) ---
# Download awg_clear_firewall_settings.sh if it doesn't exist
if [ ! -f "awg_clear_firewall_settings.sh" ]; then
    echo "Helper script 'awg_clear_firewall_settings.sh' not found. Downloading..."
    curl -L -o awg_clear_firewall_settings.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_clear_firewall_settings.sh
    chmod +x awg_clear_firewall_settings.sh
    echo "Script downloaded and made executable."
else
    echo "Helper script 'awg_clear_firewall_settings.sh' exists."
fi

# Download awg_watchdog.sh if it doesn't exist
if [ ! -f "awg_watchdog.sh" ]; then
    echo "Helper script 'awg_watchdog.sh' not found. Downloading..."
    curl -L -o awg_watchdog.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_watchdog.sh
    chmod +x awg_watchdog.sh
    echo "Script downloaded and made executable."
else
    echo "Helper script 'awg_watchdog.sh' exists."
fi

# --- INTERFACE TEARDOWN AND SETUP ---
echo "Ensuring a clean state for AmneziaWG..."
kill $(ps w | grep '[a]mneziawg-go' | awk '{print $1}') 2>/dev/null
if ip link show awg0 > /dev/null 2>&1; then
    ip link set dev awg0 down
    ip link del dev awg0
fi
sleep 1

echo "Starting AmneziaWG daemon..."
/data/usr/app/awg/amneziawg-go awg0 &
sleep 2

if ! ip link show awg0 > /dev/null 2>&1; then
    echo "Error: awg0 interface was not created. Aborting."
    exit 1
fi

echo "Configuring awg0 interface..."
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip a add "$address" dev awg0
ip l set up awg0

# --- ROUTING CONFIGURATION ---
echo "Configuring policy-based routing..."
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 table 200 pref 200

# --- FIREWALL CONFIGURATION (UCI METHOD) ---
echo "Configuring firewall rules using UCI..."

# Create a firewall zone for the VPN interface
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='REJECT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='REJECT'
uci set firewall.awg.masq='1' # This handles NAT/Masquerading
uci set firewall.awg.mtu_fix='1'

# Allow forwarding from the guest network to the VPN
uci set firewall.guest_to_awg=forwarding
uci set firewall.guest_to_awg.src='guest'
uci set firewall.guest_to_awg.dest='awg'

# Redirect all DNS requests from the guest network to the VPN's DNS server
uci set firewall.dns_redirect=redirect
uci set firewall.dns_redirect.name='Redirect-Guest-DNS-to-VPN'
uci set firewall.dns_redirect.src='guest'
uci set firewall.dns_redirect.src_dport='53'
uci set firewall.dns_redirect.proto='tcp udp'
uci set firewall.dns_redirect.target='DNAT'
uci set firewall.dns_redirect.dest_ip="$dns"

# Commit all firewall changes
uci commit firewall
echo "Restarting firewall to apply changes..."
/etc/init.d/firewall reload

# --- FINALIZATION AND PERSISTENCE ---
echo "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Get the absolute path to this script
SCRIPT_PATH=$(readlink -f "$0")
CRON_COMMAND="@reboot sleep 15 && sh $SCRIPT_PATH > /tmp/awg_startup.log 2>&1"

# Check if the cron job already exists and add it if it doesn't
if ! crontab -l 2>/dev/null | grep -qF "$CRON_COMMAND"; then
    echo "Adding cron job for auto-startup on reboot..."
    (crontab -l 2>/dev/null; echo "$CRON_COMMAND") | crontab -
    echo "Cron job added successfully."
else
    echo "Cron job for auto-startup already exists."
fi

echo "Setup complete."
