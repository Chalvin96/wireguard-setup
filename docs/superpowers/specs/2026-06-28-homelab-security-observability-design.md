# Homelab Security & Observability Stack — Design Spec

**Date:** 2026-06-28
**Project type:** DevOps portfolio

---

## Overview

Replace the CrowdSec/Suricata WAF layer with a lighter, more DevOps-idiomatic stack:
fail2ban reads Caddy's access logs, detects scanners, and enforces bans on the VPS via a
restricted SSH action. A separate monitoring VM runs Loki, Prometheus, and Grafana for
full observability over logs and metrics.

---

## Node Inventory

| Node | Role | Existing software | New software |
|---|---|---|---|
| VPS ($5) | Public ingress, ban enforcement | HAProxy, WireGuard server, ufw | nftables blocklist |
| Mini PC | Edge proxy, DNS, detection, log shipping | Caddy, AdGuard | fail2ban, Promtail |
| Monitoring VM | Observability | — | Loki, Prometheus, Grafana |

The mini PC is low-watt and already loaded. All heavy observability workloads go on the VM.

---

## Traffic Flow

```
Internet
  │
  ▼
VPS — HAProxy (:80/:443, TCP mode, send-proxy-v2)
  │         │
  │    nftables blocklist  ← banned IPs dropped here, never reach tunnel
  │
  ▼
WireGuard tunnel
  │
  ▼
Mikrotik
  │
  ▼
Mini PC — Caddy
            ├── unwrap PROXY Protocol v2 (real client IP recovery)
            ├── TLS termination
            ├── access log → /var/log/caddy/access.log (JSON)
            └── reverse proxy → backend services
```

---

## Security Automation

### Detection — fail2ban on Mini PC

fail2ban reads Caddy's JSON access log. Two filters:

**Filter 1 — scanner paths**
Triggers on requests to known scan targets: `/.env`, `/wp-admin`, `/wp-login.php`,
`/xmlrpc.php`, `/.git/`, `/phpmyadmin`, `/admin`, `/shell`, etc.
Threshold: 3 hits within 60 seconds from the same IP.

**Filter 2 — 404 flood**
Triggers on excessive 404 responses: 20 within 60 seconds from the same IP.
Catches generic path enumeration tools (dirb, gobuster, ffuf). Higher threshold than
scanner paths to avoid false positives from legitimate users hitting broken links.

**Incremental ban durations (bantime.increment):**

| Offence | Duration |
|---|---|
| 1st | 5 minutes |
| 2nd | 25 minutes |
| 3rd | 2.5 hours |
| 4th | 5 hours |
| 5th+ | 25 hours |

### Enforcement — nftables on VPS

**ufw interaction:** ufw manages its own nftables rules on Ubuntu. To avoid conflicts,
the `vps-blocklist` Ansible role disables and stops ufw (`systemctl disable --now ufw`)
before writing the blocklist table. HAProxy is already handling ingress; ufw is not needed.

The blocklist is declared in `/etc/nftables.d/blocklist.nft` and loaded via
`nft -f` — idempotent because the file begins with `flush table inet filter` scoped
to this table only. The `nftables` systemd service loads it on boot.

```
# /etc/nftables.d/blocklist.nft
table inet filter {
    set blocklist {
        type ipv4_addr
        flags timeout
    }
    chain input {
        type filter hook input priority 0
        ip saddr @blocklist drop
    }
}
```

Banned IPs are inserted with a TTL matching the fail2ban bantime.
nftables auto-removes expired entries — no unban action needed.

### SSH Action — Least-Privilege Design

fail2ban on the mini PC SSHes to the VPS to insert the IP. The connection is locked down:

**On VPS:**
- Dedicated `banagent` system user, no login shell.
- Wrapper script `/usr/local/bin/ban-ip` validates IP and timeout format (regex) before
  calling nft. Runs via sudoers with `NOPASSWD` for that one command only.
- SSH `authorized_keys` uses `command=` forced command so the key can only trigger
  the wrapper. Flags: `no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding`.

**On Mini PC:**
- Dedicated key at `/root/.ssh/vps_ban` (ed25519, no passphrase).
- `StrictHostKeyChecking=yes` in the SSH action to prevent MITM.

fail2ban action:
```
actionban   = ssh -i /root/.ssh/vps_ban banagent@<vps_ip> "<ip> %(bantime)s"
actionunban =    # empty — nftables TTL handles expiry
```

---

## Observability

### Log pipeline

```
Mini PC: Promtail
  ├── tails /var/log/caddy/access.log   (label: job=caddy)
  ├── tails /var/log/fail2ban.log       (label: job=fail2ban)
  └── ships both to Loki on Monitoring VM (port 3100)

Monitoring VM: Loki
  └── stores and indexes log streams
```

Promtail is the only observability component on the mini PC. Footprint: ~50 MB RAM.
Both log files are tailed so the Grafana ban timeline panel has a data source
(`job=fail2ban` stream in Loki).

### Metrics pipeline

```
Mini PC: Caddy metrics endpoint (<lan_ip>:2019/metrics, Prometheus format)

Monitoring VM: Prometheus
  └── scrapes Caddy metrics every 15s over LAN
```

Caddy exposes request count, latency histograms, and active connections out of the box
with `metrics` in the global Caddyfile block. No extra exporter needed.

The metrics endpoint must bind to the mini PC's LAN IP, not localhost, so the monitoring
VM can reach it. The `caddy` Ansible role sets `admin <lan_ip>:2019` in the global block.
A ufw/nftables rule on the mini PC restricts port 2019 to the monitoring VM's IP only.

### Metrics pipeline — Node Exporter

Node Exporter is installed on the monitoring VM as a systemd service via
`apt install prometheus-node-exporter`. Prometheus scrapes it on `localhost:9100`
alongside Caddy metrics. This adds host-level metrics (CPU, memory, disk) to Grafana
without any Docker complexity.

### Retention

Both Loki and Prometheus retain data for **14 days**. At homelab traffic levels this
fits well within a 20GB VM disk. Configured via:
- Loki: `retention_period: 336h` in the Loki config
- Prometheus: `--storage.tsdb.retention.time=14d` flag

### Grafana dashboards (Monitoring VM)

Five panels minimum:

| Panel | Source | Shows |
|---|---|---|
| Request rate | Prometheus | Requests/sec over time |
| 4xx/5xx rate | Prometheus | Error rate, spike detection |
| Top requested paths | Loki | Most common URIs (including scan paths) |
| Ban timeline | Loki (fail2ban log) | When bans fired, which IPs |
| Disk usage | Prometheus (Node Exporter) | VM disk % used, alert threshold |

### Grafana alerting

A single alert rule watches the monitoring VM disk usage. When disk exceeds 80%,
Grafana fires to a Discord webhook (contact point). Webhook URL stored in vault as
`vault_grafana_discord_webhook` and injected into Grafana's provisioned alerting config
by the `monitoring` Ansible role.

---

## Automation — Ansible

All node configuration is managed by Ansible from the **operator's laptop** over LAN
(mini PC and monitoring VM) and public IP (VPS). The existing shell scripts are replaced
by Ansible roles. Mikrotik remains a manual step (RouterOS does not support Ansible)
and is documented in `docs/mikrotik-wireguard-setup.md`.

### Access model

A dedicated `deploy` user is created once per host (manually or via a bootstrap playbook).
It authenticates via SSH key only (`PasswordAuthentication no`) and has full passwordless
sudo (`NOPASSWD:ALL`). Security is enforced at the SSH layer — the operator's key never
leaves their laptop. This mirrors standard CI/CD runner patterns.

### Repository layout

```
ansible/
  site.yml                        ← top-level playbook, runs all roles
  inventory/
    hosts.yml.example             ← committed, placeholder IPs, shows structure
    hosts.yml                     ← gitignored, real IPs
  group_vars/
    all/
      config.yml.example          ← committed, every variable documented with comments
      config.yml                  ← gitignored, real values (domain, ports, interface names)
      vault.yml                   ← committed, Ansible Vault encrypted
                                     contains: wireguard private keys, vps_ban SSH private key
  roles/
    wireguard-server/             ← VPS: WireGuard server setup
    haproxy/                      ← VPS: HAProxy TCP forward + send-proxy-v2
    vps-blocklist/                ← VPS: nftables blocklist + banagent user + wrapper script
    caddy/                        ← Mini PC: Caddy install + full Caddyfile template
    fail2ban/                     ← Mini PC: filters, action, SSH key deployment
    promtail/                     ← Mini PC: log shipper config
    monitoring/                   ← Monitoring VM: Docker Compose v2 (Loki + Prometheus +
                                     Grafana), Node Exporter systemd service, bind mounts
                                     under /opt/monitoring/, provisioned datasources +
                                     dashboards + Discord alert contact point
  add-client.yml                  ← standalone playbook, vars_prompt for client name
  .vault_password                 ← gitignored, used by --vault-password-file
  .gitignore
```

### Inventory groups

```yaml
# inventory/hosts.yml.example
all:
  children:
    vps:
      hosts:
        vps-01:
          ansible_host: 1.2.3.4        # replace with real VPS IP
    edge:
      hosts:
        minipc:
          ansible_host: 192.168.1.x    # replace with mini PC LAN IP
    monitoring:
      hosts:
        monitor-vm:
          ansible_host: 192.168.1.x    # replace with monitoring VM LAN IP
```

### Configuration variables (config.yml.example)

```yaml
# Network
wireguard_server_ip: "10.8.0.1"
wireguard_client_ip: "10.8.0.2"
wireguard_port: 51820
vps_public_ip: "1.2.3.4"         # real VPS IP

# Caddy
caddy_domain: "example.com"
caddy_backend_port: 8080

# fail2ban
fail2ban_ban_base: 300            # 5 minutes in seconds
fail2ban_findtime: 60
fail2ban_scanner_maxretry: 3
fail2ban_flood_maxretry: 20

# Observability
loki_port: 3100
prometheus_port: 9090
grafana_port: 3000
node_exporter_port: 9100
grafana_disk_alert_threshold: 80  # percent
```

### Secrets (vault.yml — Ansible Vault encrypted)

WireGuard keypairs are **pre-generated** on the operator's machine before the first run
(`wg genkey | tee private.key | wg pubkey > public.key`), then stored in the vault.
The roles consume them from vault variables and write keys to the correct paths on each
host. This avoids a chicken-and-egg problem where the role would need to generate keys
and then somehow populate the vault.

```yaml
# ansible-vault edit group_vars/all/vault.yml
vault_wireguard_server_private_key: "<wg private key>"
vault_wireguard_server_public_key: "<wg public key>"
vault_wireguard_client_private_key: "<wg private key>"
vault_wireguard_client_public_key: "<wg public key>"
vault_vps_ban_ssh_private_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
vault_vps_ban_ssh_public_key: "ssh-ed25519 AAAA..."
vault_grafana_admin_user: "admin"
vault_grafana_admin_password: "<strong password>"
vault_grafana_discord_webhook: "https://discord.com/api/webhooks/..."
```

### Deploy workflow

```bash
# First time
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
cp ansible/group_vars/all/config.yml.example ansible/group_vars/all/config.yml
# edit both files with real values
ansible-vault edit ansible/group_vars/all/vault.yml   # add real secrets

# Deploy everything
ansible-playbook ansible/site.yml --vault-password-file .vault_password

# Deploy one node only
ansible-playbook ansible/site.yml --limit vps --vault-password-file .vault_password
```

### Adding WireGuard clients

`add-client.yml` is a standalone Ansible playbook (not part of `site.yml`). It uses
`vars_prompt` to ask for the client name interactively, delegates to the VPS to generate
the keypair and add the peer, then prints the client config via `debug`. Zero-downtime
via `wg syncconf`.

```bash
ansible-playbook ansible/add-client.yml --vault-password-file .vault_password
# Enter client name: phone
```

### What stays as documentation (not automated)

- Mikrotik WireGuard config — `docs/mikrotik-wireguard-setup.md`

---

## Out of Scope

- IPv6 banning (nftables set is `ipv4_addr` only for now)
- TLS inspection / HTTPS payload scanning
- Alerting beyond disk usage (request rate spikes, ban rate anomalies) — add later
- Suricata / network-layer IDS
- Kubernetes or container orchestration on the mini PC

---

## DevOps Skills Demonstrated

| Skill area | Evidence |
|---|---|
| Networking | WireGuard, HAProxy TCP mode, PROXY Protocol v2, nftables |
| Security ops | fail2ban incremental banning, least-privilege SSH, automated enforcement |
| Configuration management | Ansible roles, inventory groups, idempotent playbooks |
| Secrets management | Ansible Vault, gitignored files, `.example` templates |
| Log aggregation | Promtail → Loki multi-node pipeline |
| Metrics | Prometheus scrape, Caddy native metrics |
| Observability | Grafana dashboards across logs + metrics |
| Architecture | 3-node separation of concerns (ingress / edge / observability) |
