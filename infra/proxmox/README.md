# Proxmox VM hardware with OpenTofu

OpenTofu manages VM CPU, RAM, disks, and the network adapter. Debian's installer
partitions the guest disks; Ansible configures services afterward. This uses an
ISO already uploaded through Proxmox, so no SSH access to the hypervisor or
cloud-init template is required. It does not install or reconfigure Proxmox itself.

The default VM map is empty. No existing VM is automatically adopted. The
boot disk is 64 GB and the data disk is 128 GB; install Debian with `/` on
the boot disk and `/srv` on the data disk. Set `boot_storage` and `data_storage`
to the intended Proxmox datastores. Reserve the configured MAC/IP in MikroTik.

## Connect

Install OpenTofu 1.13.1 or later. The provider is pinned and its lock file is
committed. Use a dedicated Proxmox API token with permissions for the intended
VMs and storage; follow the provider's [API token instructions](https://bpg.sh/docs/#api-token-authentication).
With privilege separation enabled, grant the required permissions to both the
user and its token. Trust the Proxmox CA on the control machine so HTTPS
certificate verification remains enabled.

```bash
export PROXMOX_VE_ENDPOINT='https://pve.example.com:8006/'
read -rsp 'Proxmox API token (user@realm!token=secret): ' PROXMOX_VE_API_TOKEN
echo
export PROXMOX_VE_API_TOKEN
cd infra/proxmox
umask 077
tofu init
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with real node/storage names, an unused VM ID, its
reserved MAC, and the uploaded ISO's file ID. This file is gitignored. For
initial installation keep `started = false`, create the hardware, then set it
to `true` and apply to boot into the installer.

```bash
tofu fmt -check
tofu validate
tofu plan -out=review.tfplan
tofu show review.tfplan
tofu apply review.tfplan
unset PROXMOX_VE_API_TOKEN
```

After Debian installation, set `iso_file_id = "none"` and leave `started = true`.
Verify key login, then use `./run.sh bootstrap --limit <host> -e ansible_user=<user> -K`
and the host's normal Ansible play from the repository root.

## Existing VMs

For an existing VM, first copy its exact hardware settings into this configuration.
Do not use the example as a declaration of sindri's existing hardware. Specify
its current running state explicitly; the default is stopped.

```bash
tofu import 'proxmox_virtual_environment_vm.vm["sindri"]' '<node>/<vm-id>'
tofu plan
```

Import updates local state, not the live VM. Resolve every unexpected difference
before applying. `prevent_destroy` blocks deletion and replacement while the
resource remains configured; it does not protect against removing the entire
resource declaration or destructive in-place changes such as removing disks.

State, backups of state, variable files, and saved plans stay local and are
gitignored. Back up the state securely; losing it prevents reliable management
of existing resources. One operator runs OpenTofu at a time. A remote backend
is unnecessary until multiple operators need shared state.
