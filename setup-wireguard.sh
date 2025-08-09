#!/bin/bash

set -e

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

echo "Installing WireGuard..."
apt update
apt install -y wireguard qrencode ufw

echo "Generating keys..."
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

echo "Selecting random port..."
WG_PORT=$((50000 + RANDOM % 10000))

MAIN_INTERFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)

echo "Creating configuration..."
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.8.0.1/24
ListenPort = $WG_PORT
SaveConfig = true

# Enable NAT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
EOF

echo "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

echo "Configuring firewall..."
ufw allow $WG_PORT/udp
ufw allow ssh

# Enable firewall
ufw --force enable

echo "Starting WireGuard..."
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "Setup complete!"
echo "Server public key: $PUBLIC_KEY"
echo "Server IP: 10.8.0.1"
echo "Port: $WG_PORT"
