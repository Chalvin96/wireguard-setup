# CI runners

CI runs on a dedicated VM, `ci-01`, with one rootful Docker daemon
(`docker.service`) and nothing else on it. The runner home
(`github_runner_home`) and the Docker data are on its boot disk.

```bash
./run.sh bootstrap --limit ci-01 -e ansible_user=<your_user> -k -K
./run.sh ci-01 --check --diff
./run.sh ci-01
```

## Runners

Each `github_runner_repos` entry gets `runners` runners (default 1): units
`actions-runner@<repo>.service`, then `actions-runner@<repo>-2.service` and so
on, each in `<github_runner_home>/<name>`. Each runner has its own
`DOCKER_CONFIG`, so registry logins do not leak between jobs. All runners
run as **root** and share `HOME=<github_runner_home>`: Docker access is
root-equivalent anyway, and root can remove the workspace files that containers
write. Each runner gets `TMPDIR=<github_runner_home>/tmp`, so files left in the
shared `/tmp` cannot break later jobs.

The rootful daemon (`/etc/docker/daemon.json`) stores its data under
`github_runner_docker_data_root`, binds published ports to `127.0.0.1` by
default and puts every container in `ci.slice`. The runners run in the same
slice, so `github_runner_slice_cpu_quota` and `github_runner_slice_memory_max`
cap all CI work together and leave memory for the OS. Actions service
containers still publish on `0.0.0.0`, so `ci-docker-lan-block.service` drops new
connections from the LAN interface (`github_runner_lan_interface`) in
`DOCKER-USER`, for IPv4 and IPv6.

CI jobs are root on this VM. Keep runners restricted to trusted private
repositories. Concurrent jobs share one daemon, so workflows must not
assume exclusive host ports or remove other jobs' containers.

The runner role seeds the configured Node versions into `RUNNER_TOOL_CACHE`
from `nodejs.org`, verifies the official SHA-256 checksums and executables, and
writes the completion markers expected by `actions/setup-node`. Bump
`github_runner_node_versions` when updating supported Node versions.

Runner units use `KillMode=control-group`, so stopping a runner also stops its
listener and job processes. Docker-created containers are separate: this is not
a replacement for scoped container cleanup.

## Cleanup and monitoring

`ci-maintenance` installs Node Exporter and an hourly cleanup
(`/etc/cron.d/ci-cleanup`) that does nothing while a job is active
(`Runner.Worker`). Otherwise it prunes containers stopped for 24 hours, unused
images and build cache older than 72 hours, and unused volumes. Prometheus
scrapes the VM as job `ci`; Grafana alerts when its metrics go missing, cleanup
fails or is overdue, or the disk passes 85%.

## Verification

After a deploy, check that `systemctl show ci.slice -p CPUQuotaPerSecUSec -p
MemoryMax` matches the configuration and that a CI workflow run succeeds.
