# Architecture & Domain Notes

Vocabulary and cross-role contracts for this codebase. Roles, task files and
templates are **modules**; the variables, handler names, paths and host-group
conventions they require are their **interfaces**.

## Nodes

- **ingress** — the public VPS. Terminates nothing; HAProxy forwards TCP with
  PROXY protocol v2 over the WireGuard tunnel.
- **edge** — the Edge node on the LAN. Runs Caddy (TLS termination, reverse
  proxy), the CrowdSec LAPI, and promtail.
- **monitoring** — the LAN VM running the Dockerized Prometheus/Loki/Grafana
  stack.

## Network contract

The cross-node agreements that make the system work, named in
`ansible/group_vars/all/config.yml` and asserted by each play's preflight in
`site.yml`:

- `wireguard_server_ip` / `wireguard_client_ip` — the tunnel endpoints
  (consumed by wireguard-server, caddy's PROXY allow-list, the LAPI firewall
  fence, haproxy backends, and the VPS bouncer).
- `crowdsec_lapi_port` — one port, five consumers (LAPI bind, firewall fence,
  both bouncers, blocklist-import).
- `caddy_admin_port` — Caddy admin/metrics bind, the edge firewall ACL, and
  the Prometheus scrape target.

## Shared rituals (deep seams)

- **apt_repo** (`ansible/tasks/apt_repo.yml`) — the keyring → signing key →
  repo → packages sequence. Interface: `apt_repo_name`, `apt_repo_key_url`,
  `apt_repo_repo`, `apt_repo_packages`. Every role that adds an apt source
  includes this; none transcribe it.
- **nft_dropin** (`ansible/tasks/nft_dropin.yml`) — a self-sufficient
  `/etc/nftables.d` drop-in: package, directory, include line
  (`create: true`), service. Interface: `nft_dropin_name`,
  `nft_dropin_template` (resolved in the calling role's `templates/`). The
  caller provides a `Reload nftables` handler. Exception: wireguard-server
  manages NAT via `PostUp` iptables in `wg0.conf.j2`, deliberately outside
  this ritual.
- **docker** (`roles/docker`) — Docker CE install, distro-aware key and repo.
  Used by crowdsec-lapi and monitoring.

## CrowdSec split

- **crowdsec-lapi** — edge only: agent, LAPI config, Hub collections,
  bouncer-key registration, blocklist-import container.
- **crowdsec-bouncer** — topology-agnostic firewall bouncer. Interface:
  `crowdsec_lapi_host` + `crowdsec_bouncer_api_key`, set per play in
  `site.yml`. Templates contain no `group_names` conditionals.
- Ordering: the **edge play runs first** in `site.yml` so the LAPI and its
  registered keys exist before the VPS bouncer starts.

## Settled decisions

- **Caddyfile site blocks are hand-authored.** This repo scaffolds Caddy
  (install, global options, PROXY listener wrappers, DNS-01); actual site
  blocks live in `/etc/caddy/conf.d/*.caddy`, written by the operator.
- **CrowdSec pins `bookworm` on Debian** — packagecloud publishes no trixie
  build yet.
- **Global `listener_wrappers`** (PROXY protocol fenced to the WireGuard
  server IP) applies to all sites by design: everything Caddy serves arrives
  via the tunnel; direct-LAN consumers bypass Caddy.
- **banagent stays.** The `ssh banagent@ingress "ip seconds"` emergency-ban
  path documented in the README is a live manual tool, even though the
  fail2ban action that once called it automatically was removed as dead code.
