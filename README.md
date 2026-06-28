# Homelab Security & Observability Stack

Automated Ansible project replacing a collection of shell scripts, provisioning three nodes (a Hetzner/DigitalOcean VPS, a Mini PC acting as an edge proxy, and a dedicated Monitoring VM). The stack implements WireGuard VPN tunneling, HAProxy TCP forwarding with PROXY Protocol v2 for real-IP recovery, nftables-based ban enforcement, fail2ban scanner detection, Caddy as a TLS-terminating reverse proxy, and a full Loki + Prometheus + Grafana observability pipeline — all driven from a single `ansible-playbook` command.

## Architecture

```
Internet
  │
  ▼
VPS (Hetzner/DigitalOcean)
  ├── HAProxy :80/:443 → TCP mode, send-proxy-v2
  └── nftables blocklist ← banned IPs dropped here
  │
  WireGuard tunnel
  │
  ▼
Mikrotik (manual — RouterOS has no Ansible support)
  │
  ▼
Mini PC — Caddy
  ├── Unwraps PROXY Protocol v2 (real client IP)
  ├── TLS termination
  ├── JSON access logs → fail2ban
  └── Reverse proxy → backend services

fail2ban (Mini PC)          Promtail (Mini PC)
  └── SSH ban action ──→      └── ships logs ──→
      VPS nftables TTL            Loki (Monitoring VM)
                                    │
                              Prometheus ← Caddy metrics
                                    │
                                  Grafana dashboards + Discord alerts
```

## Node Inventory

| Node | Role | Software |
|------|------|----------|
| VPS | Public ingress + ban enforcement | HAProxy, WireGuard server, nftables |
| Mini PC | Edge proxy + detection + log shipping | Caddy, fail2ban, Promtail |
| Monitoring VM | Observability | Loki, Prometheus, Grafana (Docker Compose) |

## Security Design

- **fail2ban incremental banning** (5m → 25m → 2.5h → 5h → 25h) reads Caddy JSON access logs to detect scanners and brute-force attempts.
- **Cross-node ban enforcement**: fail2ban SSHes as a least-privilege `banagent` user to the VPS and inserts a TTL-based nftables entry — bans auto-expire with no unban action required.
- **Ansible Vault (AES-256)** encrypts all secrets; `.example` files are committed as documentation, real configs are gitignored.
- **PROXY Protocol v2** carries the real client IP through the HAProxy → WireGuard → Caddy chain, ensuring IP-based detection and banning operates on the actual source address.

## Prerequisites

- Ansible 2.14+ and `ansible-lint` installed on the operator's laptop
- Install required collections: `ansible-galaxy collection install -r ansible/requirements.yml`
- Three nodes (VPS + Mini PC + Monitoring VM) running Debian/Ubuntu
- Mikrotik configured manually (see `docs/mikrotik-wireguard-setup.md`)

## Quick Start

```bash
# 1. Copy and fill in config files
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
cp ansible/group_vars/all/config.yml.example ansible/group_vars/all/config.yml
# Edit both files with real IPs, domain, ports

# 2. Pre-generate WireGuard and ban SSH keypairs, add to vault
ansible-vault edit ansible/group_vars/all/vault.yml

# 3. Bootstrap deploy user on each host (one-time)
ansible-playbook ansible/bootstrap.yml -u <your_user> --ask-pass --ask-become-pass

# 4. Deploy everything
ansible-playbook ansible/site.yml --vault-password-file ansible/.vault_password

# 5. Add a WireGuard client
ansible-playbook ansible/add-client.yml --vault-password-file ansible/.vault_password
```

## Repository Layout

```
ansible/
  site.yml              ← deploy all roles in dependency order
  add-client.yml        ← add WireGuard peer (interactive)
  bootstrap.yml         ← one-time: create deploy user + SSH key
  inventory/
    hosts.yml.example   ← committed template (real file gitignored)
  group_vars/all/
    config.yml.example  ← all variables documented (real file gitignored)
    vault.yml           ← Ansible Vault encrypted secrets
  roles/
    wireguard-server/   ← VPS: WireGuard server
    haproxy/            ← VPS: TCP forward + PROXY Protocol v2
    vps-blocklist/      ← VPS: nftables blocklist + banagent
    caddy/              ← Mini PC: reverse proxy + metrics
    fail2ban/           ← Mini PC: scanner detection + ban action
    promtail/           ← Mini PC: log shipping to Loki
    monitoring/         ← Monitoring VM: Docker Compose observability stack
```

## Skills Demonstrated

| Area | Implementation |
|------|----------------|
| Infrastructure as Code | Ansible roles, idempotent playbooks, inventory groups |
| Networking | WireGuard VPN, HAProxy TCP mode, PROXY Protocol v2, nftables |
| Security | fail2ban incremental banning, least-privilege SSH, Ansible Vault |
| Observability | Loki log aggregation, Prometheus metrics, Grafana dashboards |
| Secrets management | Ansible Vault AES-256, gitignored configs, `.example` templates |
| CI | GitHub Actions ansible-lint on push |
