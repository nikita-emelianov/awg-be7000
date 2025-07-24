#!/bin/sh

# Ensure script runs from its own directory
cd "$(dirname "$(readlink -f "$0")")" || exit 1

# Config paths
CONFIG="amnezia_for_awg.conf"
IFCONFIG="awg0.conf"

# Verify main config exists
[ -f "$CONFIG" ] || { echo "Config '$CONFIG' not found."; exit 1; }

# Extract IP address and first DNS
ADDRESS=$(awk -F' = ' '/^Address/ {print $2}' "$CONFIG")
DNS=$(awk -F' = ' '/^DNS/ {print $2}' "$CONFIG" | cut -d',' -f1)

echo "Client IP: $ADDRESS"
echo "DNS: $DNS"

# Generate interface config if missing
[ -f "$IFCONFIG" ] || { awk '!/^Address/ && !/^DNS/' "$CONFIG" > "$IFCONFIG"; echo "Created $IFCONFIG"; }

# Download binaries if missing
if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
  echo "Downloading binaries..."
  curl -L -o awg.tar.gz https://github.com/nikita-emelianov/awg-be7000/raw/main/awg.tar.gz
  tar -xzf awg.tar.gz && chmod +x awg amneziawg-go && rm awg.tar.gz
else
  echo "Binaries already present"
fi

# Download helper scripts if missing
[ -f "awg_clear_firewall_settings.sh" ] || curl -L -o awg_clear_firewall_settings.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_clear_firewall_settings.sh && chmod +x awg_clear_firewall_settings.sh
[ -f "awg_watchdog.sh" ] || curl -L -o awg_watchdog.sh https://github.com/nikita-emelianov/awg-be7000/raw/main/awg_watchdog.sh && chmod +x awg_watchdog.sh

# Clean previous state
echo "Cleaning up previous state..."
pkill -f amneziawg-go 2>/dev/null
ip link del awg0 2>/dev/null

# Start daemon
echo "Starting amneziawg-go..."
/data/usr/app/awg/amneziawg-go awg0 &

# Wait for the interface to be created (replaces 'sleep 2')
echo "Waiting for awg0 interface..."
count=0
while ! ip link show awg0 > /dev/null 2>&1; do
    sleep 1
    count=$((count+1))
    if [ "$count" -ge 15 ]; then
        echo "Error: awg0 interface not created after 15 seconds. Aborting."
        pkill -f amneziawg-go # Clean up the failed daemon
        exit 1
    fi
done
echo "awg0 interface is up."

# Configure interface
echo "Configuring awg0..."
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
ip addr add "$ADDRESS" dev awg0
ip link set up awg0

# Lower MTU for guest bridge
ip link set dev br-guest mtu 1280

# Routing
echo "Applying routing rules..."
ip route del 192.168.33.0/24 dev br-guest 2>/dev/null
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
ip rule add from 192.168.33.0/24 table 200 pref 200

# Firewall rules
echo "Applying iptables rules..."
iptables -F FORWARD
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -t mangle -F

# Allow DNS to router
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT

# Guest ↔ VPN
iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o br-guest -j ACCEPT

# NAT for DNS (force to VPN DNS)
iptables -t nat -A PREROUTING -i br-guest -p udp --dport 53 -j DNAT --to-destination "$DNS"
iptables -t nat -A PREROUTING -i br-guest -p tcp --dport 53 -j DNAT --to-destination "$DNS"
iptables -A FORWARD -i br-guest -p udp --dport 53 ! -d "$DNS" -j REJECT
iptables -A FORWARD -i br-guest -p tcp --dport 53 ! -d "$DNS" -j REJECT

# Block DNS-over-TLS (DoT)
iptables -A FORWARD -i br-guest -p tcp --dport 853 -j REJECT

# (Optional) Block common DNS-over-HTTPS IPs (Google/Cloudflare/Quad9)
iptables -A FORWARD -i br-guest -d 1.1.1.1 -j REJECT
iptables -A FORWARD -i br-guest -d 8.8.8.8 -j REJECT
iptables -A FORWARD -i br-guest -d 9.9.9.9 -j REJECT

# NAT for general guest → VPN traffic
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# MSS Clamping for MTU issues
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg0 -j TCPMSS --clamp-mss-to-pmtu

# UCI firewall zone
echo "Configuring UCI firewall..."
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='ACCEPT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='ACCEPT'
uci set firewall.awg.masq='1'
uci set firewall.awg.mtu_fix='1'

# Forwarding rules if missing
if ! uci show firewall | grep -qE "src='awg'|dest='awg'"; then
  uci add firewall forwarding
  uci set firewall.@forwarding[-1].src='guest'
  uci set firewall.@forwarding[-1].dest='awg'
  uci add firewall forwarding
  uci set firewall.@forwarding[-1].src='awg'
  uci set firewall.@forwarding[-1].dest='guest'
fi

uci commit firewall

# Final steps
echo "Reloading firewall..."
ip route flush cache
/etc/init.d/firewall reload
echo 1 > /proc/sys/net/ipv4/ip_forward

# Watchdog cron job
CRON_CMD="* * * * * sh /data/usr/app/awg/awg_watchdog.sh > /dev/null 2>&1"
crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh" || {
  echo "Adding watchdog to cron..."
  (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
}

echo "Setup complete."
