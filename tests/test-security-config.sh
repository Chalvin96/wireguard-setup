#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import subprocess
import tempfile
import yaml

# Secret destinations must protect both controller output and local readers.
roles = Path('ansible/roles')
for path, destinations in (
    (roles / 'wireguard-server/tasks/main.yml', {'/etc/wireguard/wg0.conf': '0600'}),
    (roles / 'caddy/tasks/main.yml', {'/etc/caddy/cloudflare.env': '0600'}),
    (roles / 'monitoring/tasks/main.yml', {
        '/opt/monitoring/docker-compose.yml': '0600',
        '/opt/monitoring/grafana/provisioning/alerting/contactpoints.yml': '0640',
    }),
    (Path('ansible/notifications.yml'), {
        '/opt/monitoring/grafana/provisioning/alerting/contactpoints.yml': '0640',
    }),
):
    document = yaml.safe_load(path.read_text())
    tasks = document[0]['tasks'] if path.name == 'notifications.yml' else document
    found = set()
    for task in tasks:
        template = task.get('ansible.builtin.template', {})
        destination = template.get('dest')
        if destination in destinations:
            assert task.get('no_log') is True, (path, destination, 'logging')
            assert task.get('diff') is False, (path, destination, 'diff')
            assert template['mode'] == destinations[destination], (path, destination, 'permissions')
            found.add(destination)
    assert found == set(destinations), (path, 'missing secret writer')

workflow = yaml.safe_load(Path('.github/workflows/lint.yml').read_text())
guard = next(step['run'] for step in workflow['jobs']['ansible-lint']['steps']
             if step.get('name') == 'Verify private configuration stays encrypted')
with tempfile.TemporaryDirectory() as directory:
    variables = Path(directory) / 'ansible/group_vars/all'
    variables.mkdir(parents=True)
    for name in ('config', 'vault'):
        (variables / f'{name}.yml').write_text('$ANSIBLE_VAULT;1.1;AES256\nfixture\n')
    assert subprocess.run(['bash', '-c', guard], cwd=directory).returncode == 0
    for name in ('config', 'vault'):
        path = variables / f'{name}.yml'
        encrypted = path.read_text()
        path.write_text('private_value: fixture\n')
        assert subprocess.run(['bash', '-c', guard], cwd=directory).returncode != 0
        path.write_text(encrypted)
print('PASS: secret output/permissions and plaintext-publication guard.')
PY
