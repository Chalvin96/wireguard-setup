#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
python3 - "$repo_root" "$temporary" <<'PY'
import sys
from pathlib import Path
import yaml

root, temporary = map(Path, sys.argv[1:])
role = root / 'ansible/roles/monitoring'
tasks = []
for task in yaml.safe_load((role / 'tasks/alerting.yml').read_text()):
    template = task.get('ansible.builtin.template', {})
    name = Path(template.get('dest', '')).name
    if name not in ('rules.yml', 'sindri.yml', 'proxmox.yml'):
        continue
    task.pop('notify', None)
    template['src'] = str(role / 'templates' / template['src'])
    template['dest'] = str(temporary / name)
    tasks.append(task)
play = [{'hosts': 'localhost', 'gather_facts': False,
         'vars_files': [str(role / 'defaults/main.yml')],
         'vars': {'grafana_disk_alert_threshold': 80, 'proxmox_ip': '192.0.2.2'},
         'tasks': tasks}]
(temporary / 'play.yml').write_text(yaml.safe_dump(play, sort_keys=False))
PY
ansible-playbook -i localhost, -c local "$temporary/play.yml" >/dev/null
python3 - "$temporary" <<'PY'
import sys
from pathlib import Path
import yaml

root = Path(sys.argv[1])
groups = [group for name in ('rules', 'sindri', 'proxmox')
          for group in yaml.safe_load((root / f'{name}.yml').read_text())['groups']]
assert {group['name']: len(group['rules']) for group in groups} == {
    'disk-alerts': 1, 'sindri-health': 12, 'proxmox-health': 17,
}
rules = {rule['uid']: rule for group in groups for rule in group['rules']}
assert len(rules) == 30
assert rules['sindri-storage-warning']['data'][-1]['model']['expression'] == '$B > 90'
assert rules['sindri-storage-critical']['data'][-1]['model']['expression'] == '$B > 100'
assert rules['sindri-storage-free']['data'][-1]['model']['expression'] == '$B < 20'
assert rules['sindri-cleanup-failed']['noDataState'] == 'OK'
assert rules['sindri-penpot-api']['noDataState'] == 'Alerting'
for group in groups:
    for rule in group['rules']:
        assert rule['condition'] == 'C'
        if group['name'] != 'disk-alerts':
            assert rule['data'][0]['model']['instant'] is True
            assert rule['annotations']['measurement'].startswith('{{ with $values.A }}')
            assert rule['labels']['service'] == group['name'].removesuffix('-health')
print('PASS: thirty unique alerts, capacity thresholds, no-data policy and literal Grafana annotations.')
PY
