# Wireguard Setup for VPS

Collection of scripts to help setup VPS as a VPN server and HTTP(S) forwarder. 
HTTP(S) forwarder is used since most local ISPs don't provide public IP.
Renting a VPS is one of the ways to provide entrance to servers in your home lab

## Scripts

- `setup-wireguard.sh` - Install and configure WireGuard server
- `add-client.sh` - Generate client configurations
- `add-port-forward.sh` - Forward HTTP/HTTPS traffic to homelab server
- `routeros-wireguard-setup.txt` - MikroTik RouterOS commands to pair with VPS WireGuard and route traffic to server

## Quick Setup

### 1. VPS Setup
```bash
# Setup WireGuard server
sudo ./setup-wireguard.sh

# Add client
sudo ./add-client.sh

# Setup MikroTik with commands from routeros-wireguard-setup

# Setup port forwarding
sudo ./add-port-forward.sh 10.8.0.2
```

### 2. MikroTik Setup
Use commands from `routeros-wireguard-setup.txt` and replace placeholders:
- `<CLIENT_PRIVATE_KEY_FROM_VPS>` - from add-client.sh output
- `<SERVER_PUBLIC_KEY>` - from setup-wireguard.sh output  
- `<VPS_PUBLIC_IP>` - your VPS IP address
- `<VPS_PORT>` - WireGuard port from setup-wireguard.sh
- `LOCAL_SERVER_IP` - your home server IP (e.g. 192.168.0.2)



