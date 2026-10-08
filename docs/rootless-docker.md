# Applications and CI on the tools VM

The tools VM has two rootless Docker daemons:

| Account         | Purpose                                   | Persistent data                   |
| --------------- | ----------------------------------------- | --------------------------------- |
| `apps`          | Penpot and future trusted services        | Separate directories under `/srv` |
| `github-runner` | Private-repository CI and test containers | Runner workspaces on the HDD      |

Each daemon keeps images and build cache in its account's home. HDD bind mounts
back those homes without changing Docker paths or runner registrations:

```fstab
/srv/heavy-data/apps /var/lib/apps none bind,x-systemd.requires-mounts-for=/srv 0 0
/srv/heavy-data/actions-runner /var/lib/actions-runner none bind,x-systemd.requires-mounts-for=/srv 0 0
/srv/heavy-data/docker /var/lib/docker none bind,x-systemd.requires-mounts-for=/srv 0 0
/srv/heavy-data/containerd /var/lib/containerd none bind,x-systemd.requires-mounts-for=/srv 0 0
```

Mount `/srv` by UUID first. Set `/srv/heavy-data` to root-owned mode `0711`;
the apps and runner directories remain owned by their respective accounts with
mode `0700`. The last two mounts retain the old rootful data for rollback.
User-manager units require their home mounts before starting. Retained rootful
Docker/containerd service drop-ins require their respective data mounts too.

For a fresh VM, create the private directories and bind mounts before deploying.
For an existing VM, pause CI, stop Penpot and both user managers plus containerd,
copy with `rsync -aHAX --numeric-ids`, and verify with
`rsync -aHAXnc --numeric-ids --delete --itemize-changes` while writers remain stopped.
Keep the original SSD directories until mounted services, image/container
inventories and a Penpot backup pass verification; only then remove the originals.
HDD I/O is slower than SSD I/O; this placement prioritizes capacity.

Neither account belongs to the root-equivalent `docker` group. Their homes
and runtime directories are private. Rootful Docker is masked after migration.
Both daemons start at boot through systemd user services with lingering enabled.

The traditional `/var/run/docker.sock` path points to **CI's** socket because
GitHub's built-in job-container handling mounts that exact path. It must never
point to the applications daemon. The applications socket is explicitly selected
by the Penpot service, backup service, and configuration-management tasks.

## Existing installations

Do not simply redeploy over existing rootful containers. The ordinary Docker
role refuses a populated rootful installation. During a maintenance window:

```bash
uvx --python 3.12 --from 'ansible-core>=2.17,<2.18' ansible-playbook \
  ansible/migrate-rootless.yml --vault-password-file .vault_password \
  -e rootless_migration_confirm=true
```

Use the repository's Ansible configuration and installed collections, as with
`run.sh`. The playbook refuses active runner jobs or unknown running containers.
It transfers the existing Penpot images, pauses runners, stops application
writers, takes a final database/assets backup, and archives the stopped project
with its original numeric ownership. It remaps bind-mounted data for rootless
UIDs, verifies HTTP health and database row counts, and tests the backup service.
Application-stage failures restore the original data and service configuration.

Rollback archives contain secrets. They remain root-only under
`/srv/backups/rootless-migration`; keep them until real Penpot usage and CI have
been verified. The old rootful Docker data is retained, not pruned or deleted.
Failures during the final CI cutover need operator attention; do not assume the
application rollback block covers that later stage.

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

The combined CI user slice limits both runner instances, their direct child
processes, and CI's rootless daemon/containers (`docker_ci_cpu_quota`,
`docker_ci_memory_max`). Per-runner limits still apply. Verify the live cgroup
limits: container-only flags are insufficient to reserve capacity for apps.

This isolates Docker management and file permissions, not the shared kernel,
disk capacity, or LAN. CI can still contact published application endpoints.
Keep runners restricted to trusted private repositories. Rootless Docker is not
a VM-strength boundary for hostile jobs.

Persistent runner workspaces remain persistent. This migration does not implement
ephemeral runners or guaranteed cancellation cleanup. Use unique Compose project
names and scope cleanup to each job's disposable resources.

Both runner services use one `RUNNER_TOOL_CACHE` on the HDD. The runner role seeds
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

Docker 29.5+ supports real host networking in rootless mode. Older versions
namespace `--network host` inside RootlessKit. Still
validate Playwright, Compose integration tests, and container jobs before assuming
every existing workflow is compatible. Host ports are shared across both daemons
and both repository runners, so avoid assuming fixed ports are globally free.

## Verification

`tests/rootless-docker.yml` exercises the Docker role on a disposable systemd
Debian container. It checks both daemons are rootless, CI cannot access the apps
socket, the compatibility socket resolves to CI, and rootful Docker is masked.
Run the role twice to check idempotence. Also verify real Penpot data, its backup,
resource limits, and CI workflows on the target VM after migration.
