# Homelab Security & Observability Stack — Design Spec

**Date:** 2026-06-28  
**Updated:** 2026-06-29 (reflects final implementation — CrowdSec replaces fail2ban web detection)  
**Project type:** DevOps portfolio

---

## Overview

Replace a collection of shell scripts with idempotent Ansible roles that provision three nodes: a VPS for public ingress and ban enforcement, a Mini PC as the edge proxy and security detection engine, and a Monitoring VM for full observability. The security layer uses CrowdSec for web threat detection with proactive blocklist feeds, plus fail2ban for SSH brute-force protection on all nodes.

---

## Node Inventory

| Node | Role | Software |
|------|------|---------|
| VPS ($5/mo) | Public ingress, ban enforcement | HAProxy, WireGuard server, nftables, CrowdSec bouncer, fail2ban |
| Mini PC | Edge proxy, detection, log shipping | Caddy, CrowdSec agent + LAPI + bouncer, blocklist-import (Docker), fail2ban, Promtail |
| Monitoring VM | Observability | Loki, Prometheus, Grafana (Docker Compose) |

The Mini PC is low-watt and already loaded. All heavy observability workloads go on the VM.

---

## Traffic Flow

```
Internet
  │
  ▼
VPS — HAProxy (:80/:443, TCP mode, send-proxy-v2)
  │         │
  │    nftables: CrowdSec bouncer + fail2ban SSH bans
  │         │
  ▼
WireGuard tunnel (10.8.0.0/24)
  │
  ▼
Mikrotik (manual — RouterOS has no Ansible support)
  │
  ▼
Mini PC — Caddy
            ├── unwrap PROXY Protocol v2 (real client IP recovery)
            ├── TLS termination
            ├── access log → /var/log/caddy/access.log (JSON)
            └── reverse proxy → backend services

Mini PC — CrowdSec LAPI
            ├── reads Caddy access log
            ├── Hub scenarios: caddy, base-http-scenarios, http-cve
            ├── blocklist-import: 13 proactive threat feeds (daily, 24h TTL)
            └── pushes decisions to both bouncers
```

---

## Security Automation

### Detection — CrowdSec on Mini PC

CrowdSec is the primary web threat detection layer. It runs as an agent + LAPI on the Mini PC, reads Caddy's JSON access log, and applies Hub scenarios maintained by the CrowdSec community:

| Collection | Detects |
|------------|---------|
| `crowdsecurity/caddy` | Caddy-specific patterns |
| `crowdsecurity/base-http-scenarios` | Generic scanner paths, 404 floods, UA enumeration |
| `crowdsecurity/http-cve` | Known CVE probes (Log4Shell, Spring4Shell, etc.) |

Scenarios update automatically via `cscli hub update` on each Ansible run — no manual maintenance.

**blocklist-import** adds proactive blocking on top of reactive detection. A Docker container on the Mini PC imports 13 threat feeds daily and pushes decisions with 24-hour TTL into the LAPI:

- Spamhaus DROP + eDROP, Firehol Level 1 + 2
- Emerging Threats, DShield, CIARMY, Talos
- GreenSnow, StopForumSpam, Tor exit nodes
- CrowdSec community blocklist (ipsum)

### Detection — fail2ban on both nodes (SSH only)

fail2ban runs on both the VPS and the Mini PC for SSH brute-force protection. It bans via `nftables[type=allports]` with incremental durations:

| Offence | Duration |
|---------|----------|
| 1st | 5 minutes |
| 2nd | 25 minutes |
| 3rd | 2.5 hours |
| 4th | 5 hours |
| 5th+ | 25 hours |

fail2ban and CrowdSec use separate nftables tables — no conflict. fail2ban handles SSH (seconds-fast reaction time); CrowdSec handles web threats (richer detection, proactive blocklists).

### Enforcement — nftables bouncers

**Edge bouncer (Mini PC):** Queries local LAPI at `127.0.0.1:8080`. Drops banned IPs before they reach Caddy.

**VPS bouncer:** Queries edge LAPI at `10.8.0.2:8080` over the WireGuard tunnel. Drops banned IPs at the public ingress before they consume tunnel bandwidth.

**LAPI security model:**
- LAPI binds to `0.0.0.0:8080`
- nftables chain `crowdsec-lapi` (priority -4) restricts access:
  - `iif lo accept` — allows edge components (bouncer, blocklist-import, cscli) via loopback
  - `ip saddr != 10.8.0.1 drop` — allows only VPS over WireGuard tunnel; drops everything else
- nftables rule is applied *before* CrowdSec starts (no security window)
- The chain uses `flush chain` (not `flush table`) to preserve TTL-tracked ban sets across re-runs

### Emergency manual ban

`ban.yml` and `unban.yml` playbooks provide out-of-band enforcement via nftables. Input is validated with an IPv4 regex before being passed to `nft`.

---

## Observability

### Log pipeline

```
Mini PC: Promtail
  ├── tails /var/log/caddy/access.log   (label: job=caddy)
  ├── tails /var/log/fail2ban.log       (label: job=fail2ban)
  └── ships both to Loki on Monitoring VM (port 3100, bound to monitoring_ip)

Monitoring VM: Loki
  └── stores and indexes log streams (14-day retention)
```

### Metrics pipeline

```
Mini PC: Caddy admin endpoint (edge_ip:2019/metrics, Prometheus format)
  └── nftables rule: port 2019 allowed only from monitoring_ip

Monitoring VM: Prometheus
  ├── scrapes Caddy metrics every 15s over LAN
  └── scrapes Node Exporter (localhost:9100) for host metrics
```

Caddy exposes request count, latency histograms, and active connections out of the box via the `metrics` global block — no extra exporter needed.

### Docker port binding

All monitoring Docker ports bind to `monitoring_ip` (the monitoring VM's LAN IP), not `0.0.0.0`. This prevents Loki, Prometheus, and Grafana from being reachable from outside the LAN.

### Grafana dashboards

| Panel | Source | Shows |
|-------|--------|-------|
| Request rate | Prometheus | Requests/sec over time |
| 4xx/5xx rate | Prometheus | Error rate, spike detection |
| Top requested paths | Loki | Most common URIs |
| Ban timeline | Loki (fail2ban log) | When bans fired, which IPs |
| Disk usage | Prometheus (Node Exporter) | VM disk % with alert threshold |

### Grafana alerting

A single alert rule watches the monitoring VM disk usage. When disk exceeds `grafana_disk_alert_threshold` (default 80%), Grafana fires to a Discord webhook. Webhook URL stored in vault as `vault_grafana_discord_webhook`.

### Retention

Both Loki and Prometheus retain data for **14 days** — fits well within a 20GB VM at homelab traffic levels.

---

## Automation — Ansible

### Access model

A dedicated `deploy` user is created via `ansible/bootstrap.yml` (one-time per host). It creates the user, copies `{{ bootstrap_ssh_pubkey }}` (default `~/.ssh/id_ed25519.pub`, overridable via `-e`), and writes the sudoers entry. All subsequent playbooks run as `deploy` with passwordless sudo.

```bash
ansible-playbook ansible/bootstrap.yml -u <your_user> --ask-pass --ask-become-pass
# Non-default key:
ansible-playbook ansible/bootstrap.yml -u <your_user> --ask-pass --ask-become-pass \
  -e bootstrap_ssh_pubkey=~/.ssh/id_rsa.pub
```

### Repository layout

```
ansible/
  site.yml                        ← 3 plays: ingress / edge / monitoring (one fact-gather per host)
  add-client.yml                  ← interactive: adds WireGuard peer, writes <name>.conf locally
  bootstrap.yml                   ← one-time: create deploy user + authorized key + sudoers
  ban.yml / unban.yml             ← manual emergency IP ban/unban with input validation
  inventory/
    hosts.yml.example             ← committed, placeholder IPs
    hosts.yml                     ← gitignored, real IPs
  group_vars/all/
    config.yml.example            ← every variable documented with comments
    config.yml                    ← gitignored, real values
    vault.yml                     ← Ansible Vault AES-256 (committed encrypted)
    vault.yml.example             ← full variable reference with changeme placeholders
  roles/
    wireguard-server/             ← VPS: WireGuard server, wg0.conf (interface only),
                                     wg0-peers.conf (loaded via PostUp wg addconf)
    haproxy/                      ← VPS: TCP forward + PROXY Protocol v2 + rate limit
    vps-blocklist/                ← VPS: nftables blocklist + emergency ban-ip tool (banagent)
    fail2ban/                     ← both nodes: SSH-only, nftables backend, incremental banning
    crowdsec/                     ← edge: CrowdSec agent + LAPI + blocklist-import Docker
                                     both: nftables bouncer (edge via loopback, VPS via WireGuard)
    caddy/                        ← edge: Caddy + metrics + nftables caddy-metrics firewall
    promtail/                     ← edge: log shipping
    monitoring/                   ← monitoring VM: Docker CE, Compose stack (Loki + Prometheus
                                     + Grafana), Node Exporter, Grafana provisioning YAML
```

### Secrets (vault.yml)

WireGuard keypairs are pre-generated on the operator's machine before the first run (`wg genkey | tee private.key | wg pubkey > public.key`), then stored in the vault. CrowdSec bouncer keys are chosen by the operator and pre-registered in the LAPI via `cscli bouncers add` during the crowdsec agent play.

```yaml
vault_wireguard_server_private_key: "<wg private key>"
vault_wireguard_server_public_key:  "<wg public key>"
vault_vps_ban_ssh_private_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
vault_vps_ban_ssh_public_key:         "ssh-ed25519 AAAA..."
vault_grafana_admin_user:             "admin"
vault_grafana_admin_password:         "<strong password>"
vault_grafana_discord_webhook:        "https://discord.com/api/webhooks/..."
vault_crowdsec_vps_bouncer_key:       "<random string>"
vault_crowdsec_edge_bouncer_key:      "<random string>"
vault_crowdsec_machine_password:      "<random string>"
```

### Role execution order

`site.yml` runs in dependency order within each play:

```
1. bootstrap.yml     (one-time, separate playbook)
2. VPS play:   wireguard-server → haproxy → vps-blocklist → fail2ban → crowdsec
3. Edge play:  caddy → fail2ban → promtail → crowdsec
4. VM play:    monitoring
```

`caddy` must run before `crowdsec` on the edge (log files must exist for acquisition).

### Adding WireGuard clients

`add-client.yml` generates a keypair on the VPS, appends a peer block to `wg0-peers.conf`, applies it live via `wg addconf` (zero downtime), and writes the client `.conf` file to the operator's local directory with mode `0600`. The private key is never printed to stdout.

```bash
ansible-playbook ansible/add-client.yml --vault-password-file .vault_password
# Enter client name: phone
# → writes ./phone.conf
```

---

## Out of Scope

- IPv6 banning (nftables set is `ipv4_addr` only)
- TLS inspection / HTTPS payload scanning
- Alerting beyond disk usage (add later)
- Kubernetes or container orchestration on the Mini PC
- Mikrotik automation (RouterOS has no Ansible support — `docs/mikrotik-wireguard-setup.md`)

---

## DevOps Skills Demonstrated

| Skill area | Evidence |
|------------|----------|
| Networking | WireGuard, HAProxy TCP mode, PROXY Protocol v2, nftables |
| Security | CrowdSec collaborative detection, proactive blocklist feeds, fail2ban SSH banning, least-privilege SSH, nftables TTL bans |
| Threat intelligence | 13-feed blocklist-import, CrowdSec Hub auto-updating scenarios |
| Configuration management | Ansible roles, inventory groups, idempotent playbooks, ansible-lint production profile |
| Secrets management | Ansible Vault AES-256, gitignored files, `.example` templates |
| Log aggregation | Promtail → Loki multi-node pipeline |
| Metrics | Prometheus scrape, Caddy native metrics, Node Exporter |
| Observability | Grafana dashboards across logs + metrics, Discord alerting |
| Architecture | 3-node separation of concerns (ingress / edge / observability) |
