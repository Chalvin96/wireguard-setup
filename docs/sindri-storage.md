# CI storage and Penpot monitoring

Keep CI workspaces, Docker layers and Buildx volumes on a separate filesystem
from Penpot data. Bound build caches, remove dangling CI images, and remove each
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

Idle CI cleanup runs every thirty minutes from `/etc/cron.d/ci-cleanup`. It freezes
idle runner listeners, skips active jobs, and resumes listeners on success or
failure. Cleanup targets the CI daemon only: disposable anonymous volumes,
detached BuildKit cache volumes, stopped containers, dangling images, and a 5 GB
cache budget per builder (measured use: 2 GB). Tagged images are kept between jobs.
Dependency caches, stale workspaces and Trivy tools unused for 14 days are removed;
total `/srv` usage never triggers deletion. Capacity is watched by the 90/100 GB
alerts. Application data and backups are excluded.
Cleanup failures and samples older than six hours are monitored.

Deploy cleanup, host swap preference and alert updates with:

```bash
ansible-playbook ansible/maintenance.yml --vault-password-file .vault_password
bash tests/test-ci-cleanup.sh
```
