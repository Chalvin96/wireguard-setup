# Applications on the tools VM

The tools VM runs Penpot and future trusted services on a rootless Docker
daemon (account `apps`), with data in separate directories under `/srv`. CI
runs on its own VM; see [CI runners](ci-runners.md).

A data-disk bind mount backs the apps home:

```fstab
/srv/apps /var/lib/apps none bind,x-systemd.requires-mounts-for=/srv 0 0
```

Mount `/srv` by UUID first. The apps home is owned by `apps`, mode `0700`. The apps user manager requires its home mount
before starting.

The `apps` account does not belong to the root-equivalent `docker` group. Its
daemon starts at boot through a systemd user service with lingering enabled and
uses weekly pruning. The applications socket is explicitly selected by the Penpot
service, backup service, and configuration-management tasks.

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

## Verification

After a deploy, check that the apps daemon reports `rootless` and that a
Penpot backup succeeds.
