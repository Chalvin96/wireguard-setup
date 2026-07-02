# Mikrotik RouterOS — WireGuard client setup

RouterOS is configured manually (out of Ansible scope for now — automating it
via the community RouterOS collection is a roadmap item). These commands set
the router up as the WireGuard client (`10.8.0.2`) that receives tunnel
traffic from the VPS and forwards it to the edge node on the LAN.

Replace the placeholders before pasting:

| Placeholder | Meaning |
|---|---|
| `<CLIENT_PRIVATE_KEY_FROM_VPS>` | Private key generated for this peer (see `add-client.yml` / `wg genkey`) |
| `<SERVER_PUBLIC_KEY>` | The VPS WireGuard server public key (`vault_wireguard_server_public_key`) |
| `<VPS_PUBLIC_IP>:<VPS_PORT>` | `ingress_ip` + `wireguard_port` from `config.yml` |
| `LOCAL_SERVER_IP` | The edge node's LAN IP (`edge_ip`) |

## 1. Create the WireGuard interface

```routeros
/interface/wireguard
add listen-port=51820 name=wg-to-vps

/interface/wireguard
set wg-to-vps private-key="<CLIENT_PRIVATE_KEY_FROM_VPS>"
```

## 2. Add the VPS as a peer

```routeros
/interface/wireguard/peers
add interface=wg-to-vps \
    public-key="<SERVER_PUBLIC_KEY>" \
    endpoint="<VPS_PUBLIC_IP>:<VPS_PORT>" \
    allowed-addresses=10.8.0.0/24 \
    persistent-keepalive=25
```

## 3. Assign the tunnel address and route

```routeros
/ip/address
add address=10.8.0.2/24 interface=wg-to-vps

/ip/route
add dst-address=10.8.0.1/32 gateway=wg-to-vps
```

## 4. NAT

Masquerade outgoing tunnel traffic, and forward HTTP/HTTPS arriving from the
tunnel to the edge node:

```routeros
/ip/firewall/nat
add chain=srcnat out-interface=wg-to-vps action=masquerade

/ip/firewall/nat
add chain=dstnat in-interface=wg-to-vps \
    protocol=tcp dst-port=80 \
    action=dst-nat to-addresses=LOCAL_SERVER_IP to-ports=80

/ip/firewall/nat
add chain=dstnat in-interface=wg-to-vps \
    protocol=tcp dst-port=443 \
    action=dst-nat to-addresses=LOCAL_SERVER_IP to-ports=443
```
