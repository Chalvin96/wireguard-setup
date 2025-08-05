#!/bin/bash

set -e

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

CLIENT_NAME=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
echo "Generated client name: $CLIENT_NAME"
SERVER_CONFIG="/etc/wireguard/wg0.conf"
CLIENT_CONFIG="/etc/wireguard/clients/${CLIENT_NAME}.conf"

if [[ ! -f "$SERVER_CONFIG" ]]; then
    echo "Error: WireGuard server not found. Run setup-wireguard.sh first."
    exit 1
fi

mkdir -p /etc/wireguard/clients

# Autoincrement IP based on number of clients
CLIENT_COUNT=$(find /etc/wireguard/clients -name "*.conf" 2>/dev/null | wc -l)
NEXT_IP=$((2 + CLIENT_COUNT))

if [[ $NEXT_IP -gt 254 ]]; then
    echo "Error: No available IP addresses in 10.8.0.x range (maximum reached)"
    exit 1
fi

CLIENT_IP="10.8.0.$NEXT_IP"
echo "Assigned IP: $CLIENT_IP"

# Generating client keys
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Getting server config
SERVER_PUBLIC_KEY=$(grep PrivateKey "$SERVER_CONFIG" | cut -d' ' -f3 | wg pubkey)
SERVER_PORT=$(grep ListenPort "$SERVER_CONFIG" | cut -d' ' -f3)
SERVER_PUBLIC_IP=$(curl -s ifconfig.me)

echo "Creating client configuration..."
cat > "$CLIENT_CONFIG" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_PUBLIC_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "Adding client to server configuration..."
cat >> "$SERVER_CONFIG" << EOF

# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
EOF

echo "Reloading WireGuard..."
systemctl reload wg-quick@wg0

echo "Client added successfully!"
echo "Client name: $CLIENT_NAME"
echo "Client IP: $CLIENT_IP"
echo "Client configuration saved to: $CLIENT_CONFIG"

# Generate QR code and capture base64
TEMP_QR="/tmp/wg-qr-${CLIENT_NAME}.png"
QR_BASE64=""
if qrencode -t PNG -o "$TEMP_QR" < "$CLIENT_CONFIG" 2>/dev/null; then
    QR_BASE64=$(base64 -w 0 "$TEMP_QR")
    rm -f "$TEMP_QR"
    echo "QR Code (Base64): $QR_BASE64"
else
    echo "QR code generation failed (install qrencode package)"
fi
