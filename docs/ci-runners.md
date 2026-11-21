# CI runners

CI runs on the hosts in the `ci` group, each with one rootful Docker daemon
(`docker.service`):

- `ci-01`, a dedicated always-on VM. The runner home (`github_runner_home`)
  and the Docker data are on its boot disk.
- `tools-01`, extra capacity while its Proxmox node is on. It also runs Penpot
  on the rootless apps daemon; its runner home is bind-mounted from a separate
  CI disk, and `host_vars/tools-01.yml` caps `ci.slice` below the whole VM.
  A job running there when the node shuts down fails and must be re-run.

Runners on both hosts share the same labels; GitHub gives a job to whichever
runner is idle.

```bash
./run.sh bootstrap --limit ci-01 -e ansible_user=<your_user> -k -K
./run.sh ci --check --diff
./run.sh ci
```

## Runners

Each `github_runner_repos` entry gets `runners` runners (default 1): units
`actions-runner@<repo>.service`, then `actions-runner@<repo>-2.service` and so
on, each in `<github_runner_home>/<name>`. All runners run as **root**: Docker
access is root-equivalent anyway, and root can remove the workspace files that
containers write. Each runner has its own `HOME` and `TMPDIR` under
`<github_runner_home>/<name>`, because actions write there and concurrent jobs
must not share them. Download caches (pnpm, uv, Node) are shared through
`XDG_CACHE_HOME` and `XDG_DATA_HOME` under `<github_runner_home>`.

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
