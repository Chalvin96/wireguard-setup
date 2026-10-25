# Proxmox disk and resource alerts

Monitoring stays on `monitoring-01`. The Proxmox host exports Node Exporter
metrics on its LAN address, port 9100, with systemd IP filtering allowing only
the host and the monitoring VM. No Proxmox API token is needed: disk and storage
collection runs locally as root.

Set `proxmox_ip` and `proxmox_expected_disks` in the encrypted configuration.
List every expected SATA disk by its stable `/dev/disk/by-id/ata-...` path.
Do not rebuild that list from only the drives currently visible after a failure.
The default expected stores are `local` and `local-lvm`. Set
`proxmox_expected_storages` in encrypted configuration to include all expected stores.

Deploy only the Proxmox collector:

```bash
./run.sh proxmox-01 --tags proxmox-monitoring
```

The standalone equivalent is `ansible/proxmox-monitoring.yml`, using the normal
vault-password argument. The existing monitoring role provisions the Prometheus
target, Grafana rules, Discord notification policy, and Proxmox dashboard.
When redeploying monitoring, compare its managed scrape configuration against
any manually added targets before applying it.

## Independent cron check

`/etc/cron.d/proxmox-health` runs `/usr/local/sbin/proxmox-health` as root every
five minutes. It checks expected SATA drives, SMART overall health, damaged
sector counters, temperature (50 C by default), increases in SATA CRC errors,
expected storage availability, capacity, thin-pool metadata/data usage, and new
kernel I/O or SATA errors. This reads SMART data; it does not run disruptive
disk scans or start a self-test on each invocation.

The check records the initial CRC counters as a baseline, so historical errors
do not generate an immediate alarm. A lock prevents overlapping runs. Each
external probe has a timeout. Health metrics are written atomically under
`/var/lib/prometheus/node-exporter`; private state is kept under
`/var/lib/proxmox-health`. Missing/query-failed disks remain in the metrics.

Fault changes go directly to the configured Discord webhook, independently of
Prometheus and Grafana. Identical ongoing faults are repeated after six hours.
The check sends recovery messages and retries failed Discord deliveries on the
next invocation. It does not queue transient faults occurring solely during an
internet outage. The webhook stays in root-only `/etc/proxmox-health.json`.

```bash
sudo /usr/local/sbin/proxmox-health
sudo /usr/local/sbin/proxmox-health --test-notification
journalctl -t proxmox-health
```

## Grafana rules

The Proxmox health dashboard shows CPU, available memory, SATA presence and
temperature, storage availability/capacity, thin-pool metadata, kernel errors,
I/O pressure, and checker age. The 17 rules are defined in the monitoring role's
defaults and can be overridden through Ansible variables.

- Unavailable metrics: 3 minutes; an overdue cron sample: 15 minutes plus a
  2-minute pending period.
- Missing or unreadable disks, SMART failure, damaged sectors, unavailable
  storage, new CRC errors, or new kernel errors: alert after a short pending
  period. Metrics refresh after each five-minute disk check.
- SATA temperature at least 50 C for 10 minutes.
- Storage/filesystem usage above 90% for 10 minutes; thin-pool metadata above
  80% for 5 minutes. Cron also reports storage usage at 90% and thin-pool
  data/metadata usage at 85%.
- CPU above 90% for 15 minutes, available memory below 10% for 10 minutes,
  swap-out above 256 pages/second for 10 minutes together with available memory
  below 10% or full memory stalls above 1%, or I/O pressure above
  20% for 10 minutes.

Grafana's notification policy sends firing and resolved alerts to its existing
Discord contact point, grouping by folder and alert name and repeating ongoing
alerts every six hours. A real fault can generate both an immediate cron message
and a Grafana alert; this is intentional independent delivery.

Grafana uses SQLite WAL mode and bounded query retries to avoid contention
between alert-state writes and reads of the local configuration database.

The host must still be running to execute cron. This setup is for disk and
resource anomalies, rather than an external host-outage service.
