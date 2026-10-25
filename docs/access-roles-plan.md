# SSH access roles — proposal

Use SSH keys for authentication and narrow passwordless commands for routine
agent diagnostics. Keep deployment authority separate from debugging authority.
This is a plan; it does not install accounts, keys or sudo rules.

| Identity                    | Intended access                                                                                           |
| --------------------------- | --------------------------------------------------------------------------------------------------------- |
| Human administrator         | Interactive maintenance and recovery using the operator's own key.                                        |
| `deploy`                    | Privileged Ansible deployment using a separate deployment key. Treat this key as administrator access.    |
| `debug`                     | A dedicated agent key that can request only predefined diagnostics. No interactive shell or general sudo. |
| Application and CI accounts | Run their services and separate rootless daemons. No agent SSH login.                                     |

## Ansible ownership

Keep engine installation in `docker-engine`, rootless account/resource policy in
`docker`, and the whitelist in `app-isolation`. Each application role owns its
service and data. The monitoring role owns alert provisioning and reloads.
Keep account/key/sudo provisioning in the access/bootstrap layer, rather than
adding debugging privileges inside application roles.

## Default agent access

Create one `debug` account per managed host. Authorize a dedicated SSH key with
`restrict` and a forced, root-owned diagnostic dispatcher. Restrict the key to
trusted controller/VPN source addresses where stable addresses are available.
Do not forward SSH agents or allow tunnels, PTYs, file transfer or arbitrary commands.
Keep actual source addresses and authorized keys in encrypted deployment configuration.

Start with a few commands:

```text
ssh debug@sindri status
ssh debug@sindri logs penpot
ssh debug@sindri health
ssh debug@sindri disk
```

The dispatcher maps service names to fixed commands for that host. Its only
passwordless sudo permission is the root-owned diagnostic helper. The helper
validates every request even when invoked directly, uses argument arrays and
absolute executable paths, and sets its own environment. It must not evaluate
shell text or permit arbitrary paths, container names, units or command options.
Use bounded log output, timeouts and no pagers. Log diagnostic requests for audit.
Keep the helper and all parent directories unwritable by the debug account.

Rootful Docker access is administrator authority; rootless Docker access still
controls that account's applications and secrets. Do not add the debug account to
the Docker group or give it unrestricted `sudo docker`. See the
[Docker privilege warning](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user).

Return selected service state, container status/resource use, bounded service logs,
known health results, disk usage and listening-port summaries. Do not expose full
container inspection, environment variables, Compose configuration, private keys,
vault files or raw Docker sockets. Logs themselves can contain application secrets
or personal information, so limit their scope; a diagnostic account is still trusted
to read the allowed output.

The initial role cannot restart, deploy, exec into containers, run database commands,
prune data or change configuration. Add an exact per-service repair operation only
when there is a concrete need and explicit authorization; do not add a generic shell
or Docker permission to make one repair convenient.

## Isolate the agent's client credentials

SSH aliases or an instruction to use `debug` are not a security boundary if the
agent can still read an administrator key or use an SSH agent holding that key.
Run the agent under a separate local OS identity or unprivileged environment that
has only the debug identity and its verified known-host entries. Keep administrator
and deployment keys, vault passwords and privileged SSH-agent sockets out of it.
If the agent shares the operator's unrestricted environment, describe the debug
role as a convenience, not enforced least privilege.

## Roll out

1. Start on the tools host. Keep an administrator session and existing access open.
2. Install the account, dispatcher and narrow sudo rule with `visudo` validation.
3. Check SSH configuration with `sshd -t` before any reload.
4. Verify intended diagnostics work non-interactively. Verify shells, forwarding,
   unknown units/options, secret-file reads and write operations are rejected.
5. Give the agent only its dedicated identity and repeat the checks from that environment.
6. Roll out to other hosts with their own small service maps. Keep infrastructure
   administration and deployment as explicit separate tasks.

Revoking the debug key should remove agent access without changing application
credentials or the operator's key. This needs no new identity provider, SSH CA,
password manager service or generic permissions framework.
