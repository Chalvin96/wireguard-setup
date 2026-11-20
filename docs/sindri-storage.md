# CI storage and Penpot monitoring

Keep CI workspaces, Docker layers and Buildx volumes on a separate filesystem
from Penpot data. Bound build caches, remove unused CI images, and remove each
disposable test stack's volumes during teardown. Apply cleanup to every retained
Buildx builder; pruning the default builder does not cover separate builders.
Do not prune application volumes.

The scoped monitoring playbook installs one-minute, timeout-bounded HTTP and
PostgreSQL probes on tools-01. Node Exporter publishes their status and response
time, and Prometheus collects them through the existing `sindri` scrape job.
Grafana on monitoring-01 routes alerts through its existing Discord contact point.

Alert data is defined in `ansible/roles/monitoring/defaults/main.yml`, and both
health groups use the shared `health-rules.yml.j2` renderer.

Alerts cover data-disk usage above 90/100 GB, less than 20 GiB available, inode
exhaustion, missing host metrics, sustained I/O pressure, failed or slow Penpot
requests, failed SQL queries, and stale probe samples. Adjust capacity thresholds
when changing the storage layout; the current rules watch `/srv`.

Deploy the collector and alert rules without redeploying the rest of the stack:

```bash
ansible-playbook ansible/sindri-monitoring.yml --vault-password-file .vault_password
```

CI cleanup runs hourly from `/etc/cron.d/ci-cleanup` and does nothing while a
job is active (`Runner.Worker`). Otherwise it prunes the rootful CI daemon:
containers stopped for 24 hours, unused images and build cache older than
72 hours, and unused volumes. Application data and backups are on the separate
apps daemon and excluded. Capacity is watched by the 85% `ci_data_used_percent`
alert.
Cleanup failures and samples older than six hours are monitored.

Deploy cleanup, host swap preference and alert updates with:

```bash
ansible-playbook ansible/maintenance.yml --vault-password-file .vault_password
bash tests/test-ci-cleanup.sh
```
