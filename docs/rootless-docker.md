# Applications and CI on the tools VM

The tools VM has two Docker daemons:

| Daemon                     | Purpose                                   | Persistent data                   |
| -------------------------- | ----------------------------------------- | --------------------------------- |
| Rootless, account `apps`   | Penpot and future trusted services        | Separate directories under `/srv` |
| Rootful (`docker.service`) | Private-repository CI and test containers | Runner home under `/srv`          |

Data-disk bind mounts back the apps home and the runner home:

```fstab
/srv/apps /var/lib/apps none bind,x-systemd.requires-mounts-for=/srv 0 0
/srv/actions-runner /var/lib/actions-runner none bind,x-systemd.requires-mounts-for=/srv 0 0
```

Mount `/srv` by UUID first. The apps home is owned by `apps`, the runner home
by root; both use mode `0700`. The apps user manager requires its home mount
before starting.

The `apps` account does not belong to the root-equivalent `docker` group. Its
daemon starts at boot through a systemd user service with lingering enabled and
uses weekly pruning. The rootful daemon serves only CI; its cleanup is owned by
`ci-maintenance`. The applications socket is explicitly selected by the Penpot
service, backup service, and configuration-management tasks; `/var/run/docker.sock`
is the CI daemon.

## Existing installations

Before assigning the apps subordinate UID/GID range, the role checks for
collisions and refuses to change an existing mapping. Changing mappings later is a
data migration, not an ordinary configuration edit.

## Future services alongside Penpot

Use the `apps` account and a separate Compose project and `/srv/<service>`
directory for each trusted application. Select its daemon explicitly:

```bash
sudo -iu apps docker compose --project-directory /srv/<service> up -d
```

Rootless setup configures the account's Docker context. For system services,
specify `DOCKER_HOST=unix:///run/user/<apps-uid>/docker.sock` explicitly and use
`User=apps`, as the Penpot unit does.

Keep each project's default network. If two applications actually need direct
communication, create a shared network in the applications daemon:

```bash
sudo -iu apps docker network create apps-shared
```

Attach only the relevant application containers in each Compose file:

```yaml
services:
  app:
    networks: [default, shared]
networks:
  shared:
    external: true
    name: apps-shared
```

Penpot's database and cache stay on its project network, not `apps-shared`.
Do not share Penpot's database credentials or assets directory with unrelated
services. A shared network permits communication; it does not supply application
authentication. No speculative shared network is created before it is needed.
Caddy remains on the edge VM and connects through each application's published
tools-VM port.

Penpot's matching-version MCP service runs on the private Penpot network and is
proxied through the existing frontend; it has no separately published port.
Enable it under **Your account → Integrations → MCP Server**, generate a personal
key, then open a file and select **File → MCP Server → Connect**. Keep the key
and token-bearing connection URL out of this public repository and logs.

## CI runners

There is one runner per `github_runner_repos` entry, unit
`actions-runner@<repo>.service`, in `<github_runner_home>/<repo>`. All runners
run as **root** and share `HOME=<github_runner_home>`: Docker access is
root-equivalent anyway, and root can remove the workspace files that containers
write. Each runner gets `TMPDIR=<github_runner_home>/tmp`, so files left in the
shared `/tmp` cannot break later jobs.

The rootful daemon (`/etc/docker/daemon.json`) stores its data under
`github_runner_docker_data_root`, binds published ports to `127.0.0.1` by
default and puts every container in `ci.slice`. The runners run in the same
slice, so `github_runner_slice_cpu_quota` and `github_runner_slice_memory_max`
cap all CI work together and keep capacity free for the apps. Actions service
containers still publish on `0.0.0.0`, so `ci-docker-lan-block.service` drops new
connections from the LAN interface (`github_runner_lan_interface`) in
`DOCKER-USER`, for IPv4 and IPv6.

This is not an isolation boundary: CI has root on the host that runs Penpot.
Keep runners restricted to trusted private repositories, and use a dedicated VM
for anything untrusted. Concurrent jobs share one daemon, so use unique Compose
project names and fixed ports only where one runner per repository makes that
safe.

The runner role seeds the configured Node versions into `RUNNER_TOOL_CACHE`
from `nodejs.org`, verifies the official SHA-256 checksums and executables, and
writes the completion markers expected by `actions/setup-node`. Bump
`github_runner_node_versions` when updating supported Node versions.

Runner units use `KillMode=control-group`, so stopping a runner also stops its
listener and job processes. Docker-created containers are separate: this is not
a replacement for scoped container cleanup.

## Verification

After a deploy, check that the apps daemon reports `rootless`, that
`systemctl show ci.slice -p CPUQuotaPerSecUSec -p MemoryMax` matches the
configuration, that the runners and CI containers are in `ci.slice`, and that a
Penpot backup and a CI workflow run succeed.
