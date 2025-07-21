#!/bin/sh

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

# Downloading AmneziaWG binaries if needed
# Check if both 'awg' and 'amneziawg-go' binaries exist in the current directory
if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
    echo "AmneziaWG binaries not found. Downloading..."
    # Download the compressed archive containing the binaries
    curl -L -o awg.tar.gz https://github.com/nikita-emelianov/awg-be7000/raw/main/awg.tar.gz
    # Download a script for clearing firewall settings (if needed)
    curl -L -o clear_firewall_settings.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/clear_firewall_settings.sh
    # Extract the contents of the archive
    tar -xzvf /data/usr/app/awg/awg.tar.gz
    # Make the downloaded binaries and script executable
    chmod +x /data/usr/app/awg/amneziawg-go
    chmod +x /data/usr/app/awg/awg
    chmod +x /data/usr/app/awg/clear_firewall_settings.sh
    # Remove the downloaded archive to save space
    rm /data/usr/app/awg/awg.tar.gz
    echo "Archive downloaded and unpacked. Proceeding with awg0 interface setup."
else
    echo "AmneziaWG binaries exist, proceeding with awg0 interface setup."
fi

# --- INTERFACE SETUP AND DAEMON MANAGEMENT SECTION ---

echo "Ensuring a clean state for awg0 interface and amneziawg-go daemon..."

# 1. Stop any running amneziawg-go processes
PID=$(ps | grep '[a]mneziawg-go' | awk '{print $1}')
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

# 3. Start the amneziawg-go daemon in the background
echo "Starting amneziawg-go daemon in the background..."
/data/usr/app/awg/amneziawg-go awg0 &
sleep 2

# 4. Verify awg0 is now present
if ! ip link show awg0 > /dev/null 2>&1; then
    echo "Error: awg0 interface was not created. Aborting setup."
    exit 1
fi
echo "awg0 interface successfully created."

# 5. Apply the configuration using the 'awg' utility and assign IP
echo "Applying AmneziaWG configuration and IP address."
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip a add "$address" dev awg0
ip l set up awg0

# --- END INTERFACE SETUP AND DAEMON MANAGEMENT SECTION ---

# Delete existing route for guest network
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null

# Add new guest network routes
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
ip rule add from 192.168.33.0/24 table 200 pref 200

# Set up firewall AmneziaWG zone
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='ACCEPT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='ACCEPT'
uci set firewall.awg.masq='1'

if ! uci show firewall | grep -qE "src='awg'|dest='awg'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='guest'
    uci set firewall.@forwarding[-1].dest='awg'
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='awg'
    uci set firewall.@forwarding[-1].dest='guest'
fi
uci commit firewall

# Clear routes cache and restart firewall
echo "Restarting firewall..."
ip route flush cache
/etc/init.d/firewall reload

# Turn IP-forwarding on
echo 1 > /proc/sys/net/ipv4/ip_forward

# ------------------------------------------------------------------
# --- MAKE SCRIPT PERSISTENT ACROSS REBOOTS (AUTO-SETUP LOGIC) ---
# ------------------------------------------------------------------

# Get the absolute path to this script
SCRIPT_PATH=$(readlink -f "$0")
STARTUP_COMMAND="sleep 20 && sh $SCRIPT_PATH &"
RC_LOCAL_FILE="/etc/rc.local"

# Check if the command is already in rc.local to avoid adding it again
if ! grep -qF "$STARTUP_COMMAND" "$RC_LOCAL_FILE"; then
    echo "Adding script to startup..."
    # Use sed to insert the command before the 'exit 0' line
    sed -i "/^exit 0/i $STARTUP_COMMAND\n" "$RC_LOCAL_FILE"
    echo "Successfully added to startup. The script will now run automatically on reboot."
else
    echo "Script is already configured to run on startup."
fi

echo "Setup complete."
