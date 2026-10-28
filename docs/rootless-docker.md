# Applications and CI on the tools VM

The tools VM has two rootless Docker daemons:

| Account         | Purpose                                   | Persistent data                   |
| --------------- | ----------------------------------------- | --------------------------------- |
| `apps`          | Penpot and future trusted services        | Separate directories under `/srv` |
| `github-runner` | Private-repository CI and test containers | Runner workspaces under `/srv`    |

Each daemon keeps images and build cache in its account's home. Data-disk bind mounts
back those homes without changing Docker paths or runner registrations:

```fstab
/srv/apps /var/lib/apps none bind,x-systemd.requires-mounts-for=/srv 0 0
/srv/actions-runner /var/lib/actions-runner none bind,x-systemd.requires-mounts-for=/srv 0 0
/srv/docker /var/lib/docker none bind,x-systemd.requires-mounts-for=/srv 0 0
/srv/containerd /var/lib/containerd none bind,x-systemd.requires-mounts-for=/srv 0 0
```

Mount `/srv` by UUID first. The apps and runner directories are owned by their respective accounts with
mode `0700`. The last two mounts retain the old rootful data for rollback.
User-manager units require their home mounts before starting. Retained rootful
Docker/containerd service drop-ins require their respective data mounts too.

For a fresh VM, create the private directories and bind mounts before deploying.
For an existing VM, pause CI, stop Penpot and both user managers plus containerd,
copy with `rsync -aHAX --numeric-ids`, and verify with
`rsync -aHAXnc --numeric-ids --delete --itemize-changes` while writers remain stopped.
Keep the original boot-disk directories until mounted services, image/container
inventories and a Penpot backup pass verification; only then remove the originals.

Neither account belongs to the root-equivalent `docker` group. Their homes
and runtime directories are private. Rootful Docker is masked.
Both daemons start at boot through systemd user services with lingering enabled.
Apps use weekly pruning; CI cleanup is owned by `ci-maintenance`, installed by the deployment.

The traditional `/var/run/docker.sock` path points to **CI's** socket because
GitHub's built-in job-container handling mounts that exact path. It must never
point to the applications daemon. The applications socket is explicitly selected
by the Penpot service, backup service, and configuration-management tasks.

## Existing installations

The role refuses to touch a host that still has containers on a rootful daemon.
Move those by hand first (stop writers, back up, recreate under the apps
account); the one-off migration playbook has been removed now that it has run.

Before assigning subordinate UID/GID ranges, the role checks for collisions and
refuses to change an existing account's mappings. Changing mappings later is a
data migration, not an ordinary configuration edit.

## Future services alongside Penpot

Use the `apps` account and a separate Compose project and `/srv/<service>`
directory for each trusted application. Select its daemon explicitly:

```bash
sudo -iu apps docker compose --project-directory /srv/<service> up -d
```

Rootless setup configures the account's Docker context. For system services,
specify `DOCKER_HOST=unix:///run/user/<apps-uid>/docker.sock` explicitly and use
`User=apps`, as the Penpot unit does. Do not grant deployment jobs the apps socket
or an unrestricted `sudo -u apps`: either would defeat CI/application separation.

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

## Boundaries and CI compatibility

Every runner instance has its own account, rootless daemon and user slice
(`docker_ci_cpu_quota`, `docker_ci_memory_max` apply per instance), covering the
runner, its child processes and its containers. Per-runner limits still apply.
Verify the live cgroup limits: container-only flags are insufficient to reserve
capacity for apps.

This isolates Docker management and file permissions, not the shared kernel,
disk capacity, or LAN. CI can still contact published application endpoints.
Keep runners restricted to trusted private repositories. Rootless Docker is not
a VM-strength boundary for hostile jobs.

Persistent runner workspaces remain persistent. This setup does not implement
ephemeral runners or guaranteed cancellation cleanup. Use unique Compose project
names and scope cleanup to each job's disposable resources.

Each runner instance has its own `RUNNER_TOOL_CACHE` under its home. The runner role seeds
the configured Node versions from `nodejs.org`, verifies the official SHA-256
checksums and executables, and writes the completion markers expected by
`actions/setup-node`. Existing workflows requesting those versions can use the
local cache instead of repeatedly downloading from GitHub. Bump
`github_runner_node_versions` when updating supported Node versions; unlisted
versions still use the action's normal download behavior.

Runner units use `KillMode=control-group`, so stopping a runner also stops its
listener and direct job processes instead of leaving orphan workers accepting
more jobs. Docker-created containers are separate processes: this is not a
replacement for scoped container cleanup.

## Runner isolation

A repository can run several runners in parallel (`instances: N` on its
`github_runner_repos` entry in the private config). Each instance gets its own
account, rootless daemon, image store and Docker config, and its runner unit
joins that daemon's network namespace (`actions-runner-exec`). The daemons
disable RootlessKit host port forwarding, so ports published by one job
(`localhost:5432`, fixed test ports) exist only inside that runner's namespace
and concurrent jobs cannot collide on ports, networks, compose projects or
registry logins. The runner still runs as its unprivileged account: the unit
grants `CAP_SYS_ADMIN` only to join the namespace and the wrapper drops it before
the runner starts. After a daemon restart the runner must be restarted to join
the new namespace (the role's handler does this).

Job containers mount `/var/run/docker.sock`. The host's compatibility symlink for
that path belongs to a single account, so each CI daemon re-points it to its own
socket inside its mount namespace (`ci-docker-sock-link`, run after the daemon
starts). Without it, other instances' container jobs fail to start, or would
reach another runner's daemon.

Layers and build cache are per daemon, so each instance pulls and stores its own
images; budget disk accordingly. Validate Playwright, Compose integration tests
and container jobs against the isolated network before assuming every
workflow is compatible.

## Verification

After a deploy, check on the host that both daemons report `rootless`, that the
CI accounts cannot reach the apps socket, and that rootful Docker is masked. Also
verify a Penpot backup, the resource limits, and a CI workflow run.
