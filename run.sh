#!/usr/bin/env bash
# Clone-and-run entry point. Needs only `uv` and an SSH key authorized as `deploy`.
#
#   ./run.sh                     deploy everything (site.yml)
#   ./run.sh edge-01             deploy one host or group (--limit)
#   ./run.sh edge-01 --check --diff
#   ./run.sh bootstrap [args]    create/authorize the deploy user (bootstrap.yml)
#   ./run.sh edit-config         create or edit the encrypted group_vars/all/config.yml
#   ./run.sh edit-vault          edit the encrypted group_vars/all/vault.yml
#   ./run.sh lint                ansible-lint, same pins as CI
#
# The vault password comes from ./.vault_password when present; otherwise it is
# asked once per run and kept in RAM (/dev/shm) until the script exits.
set -euo pipefail

cd "$(dirname "$0")"

K_PYTHON="3.12"
K_ANSIBLE_CORE="ansible-core>=2.17,<2.18"
K_ANSIBLE_LINT="ansible-lint>=24.2,<25"
K_CONFIG="ansible/group_vars/all/config.yml"
K_CONFIG_EXAMPLE="ansible/group_vars/all/config.yml.example"
K_VAULT="ansible/group_vars/all/vault.yml"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

ansible_tool() {
  uvx --quiet --python "$K_PYTHON" --from "$K_ANSIBLE_CORE" "$@"
}

install_collections() {
  ansible_tool ansible-galaxy collection install -r ansible/requirements.yml -p .collections >/dev/null
}

# Sets VAULT_PASS to a password file path. Runs in the main shell so the
# cleanup trap lives until the script exits (not just a command substitution).
VAULT_PASS=""
load_vault_password() {
  if [[ -f .vault_password ]]; then
    VAULT_PASS=".vault_password"
    return
  fi
  VAULT_PASS="$(umask 077 && mktemp -p /dev/shm vaultpass.XXXXXX)"
  trap 'shred -u "$VAULT_PASS" 2>/dev/null || rm -f "$VAULT_PASS"' EXIT
  local password
  read -rsp "Vault password: " password </dev/tty
  echo >&2
  printf '%s\n' "$password" > "$VAULT_PASS"
}

edit_config() {
  local pass="$1"
  if [[ ! -f "$K_CONFIG" ]]; then
    local plain
    plain="$(umask 077 && mktemp -p /dev/shm config.XXXXXX)"
    cp "$K_CONFIG_EXAMPLE" "$plain"
    "${EDITOR:-nano}" "$plain"
    ansible_tool ansible-vault encrypt --vault-password-file "$pass" "$plain" --output "$K_CONFIG"
    shred -u "$plain"
    echo "Created encrypted $K_CONFIG"
    return
  fi
  if ! head -1 "$K_CONFIG" | grep -q '^\$ANSIBLE_VAULT'; then
    ansible_tool ansible-vault encrypt --vault-password-file "$pass" "$K_CONFIG"
    echo "Encrypted existing plaintext $K_CONFIG"
  fi
  EDITOR="${EDITOR:-nano}" ansible_tool ansible-vault edit --vault-password-file "$pass" "$K_CONFIG"
}

command="${1:-all}"
[[ $# -gt 0 ]] && shift

case "$command" in
  lint)
    install_collections
    cd ansible
    exec uvx --quiet --python "$K_PYTHON" --from "$K_ANSIBLE_LINT" --with "$K_ANSIBLE_CORE" ansible-lint "$@"
    ;;
  edit-config)
    load_vault_password
    edit_config "$VAULT_PASS"
    ;;
  edit-vault)
    load_vault_password
    EDITOR="${EDITOR:-nano}" ansible_tool ansible-vault edit --vault-password-file "$VAULT_PASS" "$K_VAULT"
    ;;
  bootstrap)
    install_collections
    load_vault_password
    ansible_tool ansible-playbook ansible/bootstrap.yml --vault-password-file "$VAULT_PASS" "$@"
    ;;
  all)
    install_collections
    load_vault_password
    ansible_tool ansible-playbook ansible/site.yml --vault-password-file "$VAULT_PASS" "$@"
    ;;
  *)
    install_collections
    load_vault_password
    ansible_tool ansible-playbook ansible/site.yml --vault-password-file "$VAULT_PASS" --limit "$command" "$@"
    ;;
esac
