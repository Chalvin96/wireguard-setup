#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT
python3 - "$repo_root" "$temporary" <<'PY'
import sys
from pathlib import Path
import yaml
root, output = map(Path, sys.argv[1:])
config = yaml.safe_load((root / 'ansible/roles/monitoring/files/grafana/provisioning/alerting/templates.yml').read_text())
output.write_text(config['templates'][0]['template'])
PY
cd "$repo_root"
DISCORD_TEMPLATE_FILE="$temporary" go test tests/discord_template_test.go
