# Application network isolation

Local-network connections are denied unless explicitly allowed by address,
protocol and destination port. Public internet access and replies to incoming
connections remain available. This contains application code execution; host root
can change host firewall rules.

On tools hosts, filtering applies to the rootless application account, including
its network proxy. CI and operator accounts are unaffected. The initial exceptions
are TCP and UDP DNS to the configured resolver. Containers retain their existing
application network for database, cache and service communication.

GlitchTip, its database and cache use a separate Compose network, with the host
bridge named `br-glitchtip`. Filtering covers both forwarded traffic and connections
to the host, including published Docker ports. GlitchTip has no local exceptions
by default. Grafana, Prometheus and Loki retain the monitoring network.

The rules cover private IPv4, carrier-grade NAT, loopback and link-local ranges,
and IPv6 loopback, private, link-local and multicast ranges. The deployment currently
has no globally routed IPv6 LAN prefixes. Add any globally addressed internal networks
to the protected ranges before enabling them; public-address destinations otherwise
remain reachable under the public-internet policy. Local service authentication
remains necessary, including for services deliberately reachable over public URLs.

## Configure allowed services

The `tools` and `monitoring` group variables select the application account or
bridge. Add deployment-specific exceptions in encrypted configuration, for example:

```yaml
tools_app_allowed_services:
  - { address: "192.168.1.1", protocol: udp, port: 53 }
  - { address: "192.168.1.1", protocol: tcp, port: 53 }
  - { address: "192.168.1.x", protocol: tcp, port: 8025 }
```

Use `tools_app_allowed_services` for the rootless applications account and
`glitchtip_allowed_services` for GlitchTip. Each list replaces its defaults, so
retain DNS when adding mail or another service to the tools whitelist.
Allow exact destinations and ports rather than an entire subnet. Exceptions accept
IPv4 addresses; resolve internal service dependencies and update the configuration
when their addresses change.

## Deploy

```bash
ansible-playbook ansible/app-isolation.yml --vault-password-file .vault_password
```

On a first installation, also apply the monitoring Compose network change before
claiming GlitchTip is isolated. The normal site deployment installs the firewall
before starting managed applications. Existing installations should deploy with a
private backup and a timed rollback, then recreate only the GlitchTip services with
the updated Compose configuration. Named volumes and credentials must be preserved.

The `app-isolation` systemd service loads only its own nftables table. Application
runtime services require it at startup. Its rules are also included in the global
nftables configuration so a global reload does not silently remove the whitelist.
Do not flush Docker's rules to apply these changes.

## Verify

From the actual application containers, check that router/hypervisor administration,
host SSH, Grafana, Prometheus and Loki are unreachable. Verify DNS, public HTTPS,
application database/cache access, Penpot API responses and GlitchTip responses.
Operator SSH, monitoring scrapes and Grafana alert evaluations must keep working.
Verify both service restarts and repeated rule application before disabling rollback.

The native regression check uses a disposable network namespace and documentation
addresses. It verifies exact TCP/UDP exceptions, denies undeclared private endpoints
and ports plus IPv4/IPv6 loopback, preserves public-address and operator access, and
loads the rules twice. It refuses to run in the host network namespace:

```bash
python tests/test_app_isolation.py render /tmp/app-isolation.nft
sudo unshare --net "$(command -v python)" tests/test_app_isolation.py /tmp/app-isolation.nft
```

The controller needs Jinja2, included with Ansible; the disposable test host needs
Python, nftables and iproute2. The regression check does not contact the internet.
