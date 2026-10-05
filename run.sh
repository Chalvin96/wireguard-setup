#!/usr/bin/env bash
# Clone-and-run entry point. Needs only `uv` and an SSH key authorized as `deploy`.
#
#   ./run.sh                     deploy everything (site.yml)
#   ./run.sh edge-01             deploy one host or group (--limit)
#   ./run.sh edge-01 --check --diff
#   ./run.sh bootstrap [args]    create/authorize the deploy user (bootstrap.yml)
#   ./run.sh edit-config         create or edit the encrypted group_vars/all/config.yml
#   ./run.sh edit-vault          edit the encrypted group_vars/all/vault.yml
#   ./run.sh lint                ansible-lint with the CI pins
#
# The vault password comes from ./.vault_password when present; otherwise it is
# asked once per run and kept in RAM (/dev/shm) until the script exits.
set -euo pipefail

cd "$(dirname "$0")"

K_PYTHON="3.12"
K_ANSIBLE_CORE="ansible-core>=2.17,<2.18"
# Lint uses exactly the pins in .github/workflows/lint.yml.
K_LINT_ANSIBLE_CORE="ansible-core>=2.16,<2.18"
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

# Plaintext files created by this script (password, new config) are removed on
# exit, including on errors and Ctrl-C.
TEMP_FILES=()
cleanup_temp_files() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    shred -u "$file" 2>/dev/null || rm -f "$file"
  done
}
trap cleanup_temp_files EXIT

# Sets VAULT_PASS_FILE: ./.vault_password when present (must be mode 0600),
# otherwise a RAM-only file holding a password read from the terminal.
VAULT_PASS_FILE=""
resolve_vault_password_file() {
  if [[ -f .vault_password ]]; then
    if [[ "$(stat -c %a .vault_password)" != "600" ]]; then
      echo ".vault_password must be mode 0600: chmod 600 .vault_password" >&2
      exit 1
    fi
    VAULT_PASS_FILE=".vault_password"
    return
  fi
  VAULT_PASS_FILE="$(umask 077 && mktemp -p /dev/shm vaultpass.XXXXXX)"
  TEMP_FILES+=("$VAULT_PASS_FILE")
  local password
  read -rsp "Vault password: " password </dev/tty
  echo >&2
  printf '%s\n' "$password" > "$VAULT_PASS_FILE"
}

edit_config() {
  local vault_pass_file="$1"
  if [[ ! -f "$K_CONFIG" ]]; then
    local plain
    plain="$(umask 077 && mktemp -p /dev/shm config.XXXXXX)"
    TEMP_FILES+=("$plain")
    cp "$K_CONFIG_EXAMPLE" "$plain"
    "${EDITOR:-nano}" "$plain"
    ansible_tool ansible-vault encrypt --vault-password-file "$vault_pass_file" "$plain" --output "$K_CONFIG"
    echo "Created encrypted $K_CONFIG"
    return
  fi
  if ! head -1 "$K_CONFIG" | grep -q '^\$ANSIBLE_VAULT'; then
    ansible_tool ansible-vault encrypt --vault-password-file "$vault_pass_file" "$K_CONFIG"
    echo "Encrypted existing plaintext $K_CONFIG"
  fi
  EDITOR="${EDITOR:-nano}" ansible_tool ansible-vault edit --vault-password-file "$vault_pass_file" "$K_CONFIG"
}

# A leading flag (./run.sh --check --diff) means "all hosts".
if [[ $# -eq 0 || "$1" == -* ]]; then
  command="all"
else
  command="$1"
  shift
fi

case "$command" in
  lint)
    install_collections
    cd ansible
    exec uvx --quiet --python "$K_PYTHON" --from "$K_ANSIBLE_LINT" --with "$K_LINT_ANSIBLE_CORE" ansible-lint "$@"
    ;;
  edit-config)
    resolve_vault_password_file
    edit_config "$VAULT_PASS_FILE"
    ;;
  edit-vault)
    resolve_vault_password_file
    EDITOR="${EDITOR:-nano}" ansible_tool ansible-vault edit --vault-password-file "$VAULT_PASS_FILE" "$K_VAULT"
    ;;
  bootstrap)
    install_collections
    resolve_vault_password_file
    ansible_tool ansible-playbook ansible/bootstrap.yml --vault-password-file "$VAULT_PASS_FILE" "$@"
    ;;
  all)
    install_collections
    resolve_vault_password_file
    ansible_tool ansible-playbook ansible/site.yml --vault-password-file "$VAULT_PASS_FILE" "$@"
    ;;
  *)
    install_collections
    resolve_vault_password_file
    ansible_tool ansible-playbook ansible/site.yml --vault-password-file "$VAULT_PASS_FILE" --limit "$command" "$@"
    ;;
esac
