# Configuration reference

Two files hold all configuration, both created by copying the `.example`
next to them. The real files are gitignored — nothing environment-specific
ever lands in the repo.

```bash
cp ansible/inventory/hosts.yml.example        ansible/inventory/hosts.yml
cp ansible/group_vars/all/config.yml.example  ansible/group_vars/all/config.yml
```

## Plain variables — `config.yml`

See [`config.yml.example`](../ansible/group_vars/all/config.yml.example) for
the full annotated list. The variables below form the **network contract** —
cross-node agreements consumed by several roles and asserted by each play's
preflight before anything is touched:

| Variable | Consumed by |
|----------|-------------|
| `wireguard_server_ip` / `wireguard_client_ip` | wireguard-server, caddy's PROXY allow-list, the LAPI firewall fence, haproxy backends, the VPS bouncer |
| `crowdsec_lapi_port` | LAPI bind, firewall fence, both bouncers, blocklist-import |
| `caddy_admin_port` | Caddy admin/metrics bind, edge firewall ACL, Prometheus scrape target |
| `edge_ip` / `monitoring_ip` | Caddy admin bind, metrics firewall, Prometheus |

## Secrets — `vault.yml` (Ansible Vault, AES-256)

See [`vault.yml.example`](../ansible/group_vars/all/vault.yml.example) for
the full list. Edit with:

```bash
ansible-vault edit ansible/group_vars/all/vault.yml
```

| Variable | Purpose |
|----------|---------|
| `vault_wireguard_server_private_key` | WireGuard server private key |
| `vault_wireguard_server_public_key` | Server public key (distributed to clients) |
| `vault_vps_ban_ssh_private_key` | Key for the emergency `banagent` command |
| `vault_vps_ban_ssh_public_key` | Public half (installed in banagent `authorized_keys`) |
| `vault_caddy_cloudflare_api_token` | Cloudflare Zone:DNS:Edit token for DNS-01 certificates |
| `vault_grafana_admin_user` / `..._password` | Grafana admin credentials |
| `vault_grafana_discord_webhook` | Discord webhook for disk alerts |
| `vault_crowdsec_vps_bouncer_key` | Pre-shared key for the VPS CrowdSec bouncer |
| `vault_crowdsec_edge_bouncer_key` | Pre-shared key for the edge CrowdSec bouncer |
| `vault_crowdsec_machine_password` | Password for the blocklist-import machine account |
