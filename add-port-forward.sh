#!/bin/bash

set -e

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <wireguard_client_ip>"
  echo "Example: $0 10.8.0.2"
  exit 1
fi

CLIENT_IP="$1"
WG_CONFIG="/etc/wireguard/wg0.conf"

if [[ ! -f "$WG_CONFIG" ]]; then
  echo "Error: WireGuard configuration not found at $WG_CONFIG"
  echo "Run setup-wireguard.sh first"
  exit 1
fi

if ! grep -q "$CLIENT_IP/32" "$WG_CONFIG"; then
  echo "Error: Client IP $CLIENT_IP not found in WireGuard configuration"
  echo "Add the client first using add-client.sh"
  exit 1
fi

if grep -q "Port forwarding rules" "$WG_CONFIG"; then
  echo "Error: Port forwarding rules already exist in WireGuard configuration"
  echo "Remove existing rules first or use a fresh configuration"
  echo ""
  exit 1
fi

echo "Setting up port forwarding to $CLIENT_IP..."

MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

cp "$WG_CONFIG" "$WG_CONFIG.backup"


# Based on https://serverfault.com/questions/1140819/forwarding-vps-traffic-over-wireguard

RULES_FILE=$(mktemp)

cat >"$RULES_FILE" <<EOF

# Port forwarding rules for HTTP/HTTPS
PostUp = iptables -P FORWARD DROP

##FORWARD Port 80, 443
PostUp = iptables -A FORWARD -i $MAIN_INTERFACE -o wg0 -p tcp --syn --dport 80 -m conntrack --ctstate NEW -j ACCEPT
PostDown = iptables -D FORWARD -i $MAIN_INTERFACE -o wg0 -p tcp --syn --dport 80 -m conntrack --ctstate NEW -j ACCEPT

PostUp = iptables -A FORWARD -i $MAIN_INTERFACE -o wg0 -p tcp --syn --dport 443 -m conntrack --ctstate NEW -j ACCEPT
PostDown = iptables -D FORWARD -i $MAIN_INTERFACE -o wg0 -p tcp --syn --dport 443 -m conntrack --ctstate NEW -j ACCEPT

##Generic Forwards
PostUp = iptables -A FORWARD -i $MAIN_INTERFACE -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D FORWARD -i $MAIN_INTERFACE -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

PostUp = iptables -A FORWARD -i wg0 -o $MAIN_INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -o $MAIN_INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

##Port 80
PostUp = iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination $CLIENT_IP:80
PostDown = iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination $CLIENT_IP:80

PostUp = iptables -t nat -A POSTROUTING -o wg0 -p tcp --dport 80 -d $CLIENT_IP -j SNAT --to-source 10.8.0.1
PostDown = iptables -t nat -D POSTROUTING -o wg0 -p tcp --dport 80 -d $CLIENT_IP -j SNAT --to-source 10.8.0.1

##Port 443
PostUp = iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination $CLIENT_IP:443
PostDown = iptables -t nat -D PREROUTING -p tcp --dport 443 -j DNAT --to-destination $CLIENT_IP:443

PostUp = iptables -t nat -A POSTROUTING -o wg0 -p tcp --dport 443 -d $CLIENT_IP -j SNAT --to-source 10.8.0.1
PostDown = iptables -t nat -D POSTROUTING -o wg0 -p tcp --dport 443 -d $CLIENT_IP -j SNAT --to-source 10.8.0.1

# End of port forwarding rules for HTTP/HTTPS


EOF

TMP_CONFIG=$(mktemp)

awk -v rules="$RULES_FILE" '
  /^\[Peer\]/ && !inserted {
    system("cat " rules);
    print "";
    inserted=1;
  }
  { print }
  END {
    if (!inserted) {
      print "";
      system("cat " rules);
    }
  }
' "$WG_CONFIG" >"$TMP_CONFIG"

mv "$TMP_CONFIG" "$WG_CONFIG"


echo "Opening firewall ports..."
ufw allow 80/tcp
ufw allow 443/tcp

echo "Restarting WireGuard..."
systemctl restart wg-quick@wg0

echo "Port forwarding setup complete!"
echo "Target IP: $CLIENT_IP"
echo "Forwarded ports: 80 (HTTP), 443 (HTTPS)"
echo "Main interface: $MAIN_INTERFACE"