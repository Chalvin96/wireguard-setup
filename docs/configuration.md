# Configuration reference

Two files hold all configuration, both created by copying the `.example`
next to them. The real files are gitignored.

```bash
cp ansible/inventory/hosts.yml.example        ansible/inventory/hosts.yml
cp ansible/group_vars/all/config.yml.example  ansible/group_vars/all/config.yml
```

## Plain variables — `config.yml`

See [`config.yml.example`](../ansible/group_vars/all/config.yml.example) for
the full annotated list.

Relevant monitoring variables now include:

| Variable | Purpose |
|----------|---------|
| `monitoring_ip` | Bind address for Grafana, Prometheus, Loki, and GlitchTip |
| `loki_port` | Loki HTTP port |
| `prometheus_port` | Prometheus HTTP port |
| `grafana_port` | Grafana HTTP port |
| `glitchtip_port` | GlitchTip HTTP port |
| `glitchtip_domain` | Public GlitchTip URL, including scheme |
| `glitchtip_enable_admin` | Enables Django admin when `true` |
| `glitchtip_enable_openapi` | Enables OpenAPI docs when `true` |

Set `glitchtip_domain` to the URL clients will use for GlitchTip. If there is
no reverse proxy route yet, use `http://<monitoring_ip>:8000`.

## Secrets — `vault.yml`

Edit with:

```bash
ansible-vault edit ansible/group_vars/all/vault.yml
```

GlitchTip adds:

| Variable | Purpose |
|----------|---------|
| `vault_glitchtip_secret_key` | Django secret key |
| `vault_glitchtip_postgres_password` | URL-safe PostgreSQL password |
| `vault_glitchtip_email_url` | Mail transport, or `consolemail://` |
| `vault_glitchtip_default_from_email` | Sender address for outbound mail |
