# Homelab Security & Observability Stack

Automated Ansible project replacing a collection of shell scripts, provisioning three nodes (a Hetzner/DigitalOcean VPS, a Mini PC acting as an edge proxy, and a dedicated Monitoring VM). The stack implements WireGuard VPN tunneling, HAProxy TCP forwarding with PROXY Protocol v2 for real-IP recovery, nftables-based ban enforcement, CrowdSec collaborative threat detection with proactive blocklist feeds, fail2ban SSH brute-force protection, Caddy as a TLS-terminating reverse proxy, and a full Loki + Prometheus + Grafana observability pipeline — all driven from a single `ansible-playbook` command.

## Architecture

```
Internet
  │
  ▼
VPS (Hetzner/DigitalOcean)
  ├── HAProxy :80/:443 → TCP mode, send-proxy-v2
  ├── nftables blocklist ← CrowdSec bouncer drops banned IPs here
  └── fail2ban → nftables (SSH brute-force)
  │
  WireGuard tunnel (10.8.0.0/24)
  │
  ▼
Mikrotik (manual — RouterOS has no Ansible support)
  │
  ▼
Mini PC — Caddy
  ├── Unwraps PROXY Protocol v2 (real client IP)
  ├── TLS termination
  ├── JSON access logs → CrowdSec + Promtail
  ├── CrowdSec agent (LAPI) + nftables bouncer
  └── Reverse proxy → backend services

CrowdSec (Mini PC)          fail2ban (both nodes)     Promtail (Mini PC)
  ├── reads Caddy access log   └── SSH brute-force         └── ships logs ──→
  ├── Hub: CVE + scanner            incremental ban             Loki (Monitoring VM)
  │   scenarios (auto-updated)      via nftables                    │
  ├── blocklist-import:        CrowdSec bouncer (VPS)        Prometheus ← Caddy metrics
  │   13 threat feeds daily        └── queries LAPI                  │
  │   (Spamhaus, Firehol,               over WireGuard         Grafana dashboards
  │    DShield, Talos, Tor…)                                    + Discord alerts
  └── nftables bouncer (edge)
```

## Node Inventory

| Node | Ansible Host | Role | Software |
|------|-------------|------|----------|
| VPS | `ingress-01` | Public ingress + ban enforcement | HAProxy, WireGuard server, nftables, CrowdSec bouncer, fail2ban |
| Mini PC | `edge-01` | Edge proxy + detection + log shipping | Caddy, CrowdSec agent + LAPI + bouncer, blocklist-import, fail2ban, Promtail |
| Monitoring VM | `monitoring-01` | Observability | Loki, Prometheus, Grafana (Docker Compose) |

## Security Design

### CrowdSec (web threat detection + proactive blocking)

CrowdSec runs on the edge node as the LAPI server. It reads Caddy's JSON access logs and applies Hub scenarios — `crowdsecurity/caddy`, `crowdsecurity/base-http-scenarios`, `crowdsecurity/http-cve` — to detect scanners, CVE probes, and flooding automatically. Scenarios are maintained by the CrowdSec community and update without config changes.

Two nftables bouncers enforce decisions:
- **Edge bouncer** (Mini PC) — drops banned IPs before they reach Caddy.
- **VPS bouncer** — queries the edge LAPI over the WireGuard tunnel and drops banned IPs at the public ingress before they consume tunnel bandwidth.

**LAPI security:** The LAPI socket binds to `0.0.0.0` but is restricted by an nftables chain (`crowdsec-lapi`) that accepts only `127.0.0.1` (loopback, for edge components) and `10.8.0.1` (VPS WireGuard IP). The nftables rule is applied before CrowdSec starts to eliminate the security window.

**blocklist-import:** A Docker container on the edge node imports 13 proactive threat feeds daily (Spamhaus DROP/eDROP, Firehol L1/L2, DShield, Emerging Threats, Talos, CIARMY, GreenSnow, StopForumSpam, Tor exits, and the CrowdSec community blocklist). Decisions carry a 24-hour TTL and refresh daily.

### fail2ban (SSH brute-force)

fail2ban runs on both the VPS and the edge node, SSH-only. Incremental banning via `nftables[type=allports]`:

| Offence | Duration |
|---------|----------|
| 1st | 5 minutes |
| 2nd | 25 minutes |
| 3rd | 2.5 hours |
| 4th | 5 hours |
| 5th+ | 25 hours |

### General

- **Ansible Vault (AES-256)** encrypts all secrets; `.example` files are committed as documentation, real configs are gitignored.
- **PROXY Protocol v2** carries the real client IP through the HAProxy → WireGuard → Caddy chain, ensuring IP-based detection and banning operates on the actual source address.
- **nftables TTL bans** auto-expire — no unban action required for either CrowdSec or fail2ban.
- **Emergency manual ban:** `ansible-playbook ansible/ban.yml` / `ansible-playbook ansible/unban.yml` for out-of-band enforcement.

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

# 2. Pre-generate WireGuard keypairs and CrowdSec bouncer keys, add to vault
#    WireGuard:  wg genkey | tee private.key | wg pubkey > public.key
#    CrowdSec:   choose strong random strings for bouncer keys and machine password
ansible-vault edit ansible/group_vars/all/vault.yml

# 3. Bootstrap deploy user on each host (one-time)
ansible-playbook ansible/bootstrap.yml -u <your_user> --ask-pass --ask-become-pass
# Override SSH key path if needed:
# ansible-playbook ansible/bootstrap.yml -u <your_user> --ask-pass --ask-become-pass \
#   -e bootstrap_ssh_pubkey=~/.ssh/id_rsa.pub

# 4. Deploy everything
ansible-playbook ansible/site.yml --vault-password-file ansible/.vault_password

# 5. Add a WireGuard client (writes <client>.conf locally)
ansible-playbook ansible/add-client.yml --vault-password-file ansible/.vault_password
```

## Repository Layout

```
ansible/
  site.yml              ← deploy all roles in dependency order (3 plays: ingress / edge / monitoring)
  add-client.yml        ← add WireGuard peer (interactive, writes client.conf locally)
  bootstrap.yml         ← one-time: create deploy user + SSH key
  ban.yml               ← manual emergency ban (prompts for IP)
  unban.yml             ← manual unban (prompts for IP, validates format)
  inventory/
    hosts.yml.example   ← committed template (real file gitignored)
  group_vars/all/
    config.yml.example  ← all variables documented (real file gitignored)
    vault.yml           ← Ansible Vault encrypted secrets
  roles/
    wireguard-server/   ← ingress-01: WireGuard server + peer management (wg0 + wg0-peers.conf)
    haproxy/            ← ingress-01: TCP forward + PROXY Protocol v2 + rate limiting
    vps-blocklist/      ← ingress-01: nftables blocklist + emergency ban-ip tool
    fail2ban/           ← both nodes: SSH brute-force incremental banning via nftables
    crowdsec/           ← edge-01: CrowdSec LAPI + Hub scenarios + blocklist-import (agent)
                           ingress-01: CrowdSec nftables bouncer (queries LAPI over WireGuard)
    caddy/              ← edge-01: reverse proxy + metrics endpoint + nftables firewall
    promtail/           ← edge-01: log shipping to Loki
    monitoring/         ← monitoring-01: Docker Compose observability stack
```

## Vault Variables Reference

See `ansible/group_vars/all/vault.yml.example` for the full list. Key variables:

| Variable | Purpose |
|----------|---------|
| `vault_wireguard_server_private_key` | WireGuard server private key |
| `vault_wireguard_server_public_key` | WireGuard server public key (distributed to clients) |
| `vault_vps_ban_ssh_private_key` | SSH key for emergency banagent access |
| `vault_vps_ban_ssh_public_key` | SSH key public half (written to VPS authorized_keys) |
| `vault_grafana_admin_user` | Grafana admin username |
| `vault_grafana_admin_password` | Grafana admin password |
| `vault_grafana_discord_webhook` | Discord webhook URL for disk alerts |
| `vault_crowdsec_vps_bouncer_key` | Pre-shared key for VPS CrowdSec bouncer |
| `vault_crowdsec_edge_bouncer_key` | Pre-shared key for edge CrowdSec bouncer |
| `vault_crowdsec_machine_password` | Password for blocklist-import machine account |

## Skills Demonstrated

| Area | Implementation |
|------|----------------|
| Infrastructure as Code | Ansible roles, idempotent playbooks, inventory groups |
| Networking | WireGuard VPN, HAProxy TCP mode, PROXY Protocol v2, nftables |
| Security | CrowdSec collaborative threat detection, proactive blocklist feeds, fail2ban SSH banning, Ansible Vault |
| Threat intelligence | 13 feed blocklist-import (Spamhaus, Firehol, DShield, Talos, Tor exits), CrowdSec Hub scenarios |
| Observability | Loki log aggregation, Prometheus metrics, Grafana dashboards + Discord alerts |
| Secrets management | Ansible Vault AES-256, gitignored configs, `.example` templates |
| CI | GitHub Actions ansible-lint on push (production profile, 0 failures) |
