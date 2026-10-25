#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/backups" "$test_dir/penpot/assets"
printf 'asset\n' > "$test_dir/penpot/assets/example"
sed -e "s|{{ penpot_backup_dir }}|$test_dir/backups|g" \
    -e "s|{{ penpot_dir }}|$test_dir/penpot|g" \
    -e 's|{{ penpot_backup_keep_days }}|7|g' \
    "$repo_root/ansible/roles/penpot/templates/penpot-backup.sh.j2" > "$test_dir/backup"
printf '#!/bin/sh\nprintf "database dump\\n"\n' > "$test_dir/bin/docker"
printf '#!/bin/sh\nexit 1\n' > "$test_dir/bin/tar"
chmod +x "$test_dir/bin/docker" "$test_dir/bin/tar"

if PATH="$test_dir/bin:$PATH" bash "$test_dir/backup"; then
  echo 'Expected assets archive failure' >&2
  exit 1
fi
test -z "$(find "$test_dir/backups" -type f -print -quit)"
rm "$test_dir/bin/tar"
PATH="$test_dir/bin:$PATH" bash "$test_dir/backup"
test "$(find "$test_dir/backups" -type f | wc -l)" -eq 2
test -z "$(find "$test_dir/backups" -type f ! -perm 0600 -print -quit)"
tar -tzf "$test_dir"/backups/penpot-assets-*.tar.gz | grep -q assets/example
echo 'PASS: failed archive leaves no published backup; success creates private dump and valid assets archive.'
