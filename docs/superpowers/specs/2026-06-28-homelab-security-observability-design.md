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
Triggers on excessive 404 responses: 10 within 60 seconds from the same IP.
Catches generic path enumeration tools (dirb, gobuster, ffuf).

**Incremental ban durations (bantime.increment):**

| Offence | Duration |
|---|---|
| 1st | 5 minutes |
| 2nd | 25 minutes |
| 3rd | 2.5 hours |
| 4th | 5 hours |
| 5th+ | 25 hours |

### Enforcement — nftables on VPS

One-time VPS setup creates a named set with timeout support:

```
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
  └── tails /var/log/caddy/access.log
  └── ships to Loki on Monitoring VM (port 3100)

Monitoring VM: Loki
  └── stores and indexes log streams
```

Promtail is the only observability component on the mini PC. Footprint: ~50 MB RAM.

### Metrics pipeline

```
Mini PC: Caddy metrics endpoint (localhost:2019/metrics, Prometheus format)

Monitoring VM: Prometheus
  └── scrapes Caddy metrics every 15s
```

Caddy exposes request count, latency histograms, and active connections out of the box
with `metrics` in the global Caddyfile block. No extra exporter needed.

### Grafana dashboards (Monitoring VM)

Four panels minimum:

| Panel | Source | Shows |
|---|---|---|
| Request rate | Prometheus | Requests/sec over time |
| 4xx/5xx rate | Prometheus | Error rate, spike detection |
| Top requested paths | Loki | Most common URIs (including scan paths) |
| Ban timeline | Loki (fail2ban log) | When bans fired, which IPs |

---

## Scripts Affected

| Script | Change |
|---|---|
| `setup-homelab-waf.sh` | Full rewrite — remove CrowdSec, add fail2ban + Promtail install and config |
| New: `setup-vps-blocklist.sh` | One-time nftables blocklist setup on VPS + banagent user + wrapper script |
| New: `setup-monitoring.sh` | Installs Loki, Prometheus, Grafana on monitoring VM via Docker Compose |

`setup-haproxy.sh`, `setup-wireguard.sh`, `add-client.sh`, and `add-port-forward.sh` are unchanged.

---

## Out of Scope

- IPv6 banning (nftables set is `ipv4_addr` only for now)
- TLS inspection / HTTPS payload scanning
- Alerting (Grafana alerts, PagerDuty, etc.) — add later
- Suricata / network-layer IDS
- Kubernetes or container orchestration on the mini PC

---

## DevOps Skills Demonstrated

| Skill area | Evidence |
|---|---|
| Networking | WireGuard, HAProxy TCP mode, PROXY Protocol v2, nftables |
| Security ops | fail2ban incremental banning, least-privilege SSH, automated enforcement |
| Log aggregation | Promtail → Loki multi-node pipeline |
| Metrics | Prometheus scrape, Caddy native metrics |
| Observability | Grafana dashboards across logs + metrics |
| Architecture | 3-node separation of concerns (ingress / edge / observability) |
