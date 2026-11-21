#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/metrics"
python3 - "$repo_root" "$temporary" <<'PY'
import shlex
import sys
from pathlib import Path
from jinja2 import Environment
root, temporary = map(Path, sys.argv[1:])
environment = Environment(trim_blocks=True)
environment.filters['quote'] = shlex.quote
source = (root / 'ansible/roles/ci-maintenance/templates/ci-cleanup.sh.j2').read_text()
source = source.replace('/run/lock/ci-cleanup.lock', str(temporary / 'lock'))
source = source.replace('/var/lib/prometheus/node-exporter', str(temporary / 'metrics'))
(temporary / 'cleanup').write_text(environment.from_string(source).render(github_runner_home='/ci home', ci_cleanup_pressure_percent=80))
PY
cat > "$temporary/bin/docker" <<'EOF2'
#!/bin/bash
echo "docker $*" >> "$CALLS"
[[ "$*" != *"${FAIL_ON:-never}"* ]]
EOF2
cat > "$temporary/bin/df" <<'EOF2'
#!/bin/bash
[[ "$*" == '--output=pcent /ci home' ]] || exit 2
printf 'Use%%\n %s%%\n' "${DF_PCT:-42}"
EOF2
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH" CALLS="$temporary/calls"
metric() { grep -qx "$1" "$temporary/metrics/$2.prom"; }

# Normal: the light prunes run, even while jobs are active.
: > "$CALLS"
bash "$temporary/cleanup"
diff - "$CALLS" <<'EOF2'
docker container prune -f --filter until=6h
docker image prune -f
docker volume prune -f
docker builder prune -af --filter until=24h
EOF2
metric 'ci_cleanup_success 1' ci-cleanup
grep -q '^ci_cleanup_last_run_timestamp_seconds [0-9]\+$' "$temporary/metrics/ci-cleanup.prom"
metric 'ci_data_used_percent 42' ci-disk

# Disk pressure: all unused images, volumes and cache go too.
: > "$CALLS"
DF_PCT=85 bash "$temporary/cleanup"
diff - "$CALLS" <<'EOF2'
docker container prune -f --filter until=6h
docker image prune -f
docker volume prune -f
docker builder prune -af --filter until=24h
docker image prune -af
docker volume prune -af
docker builder prune -af
EOF2
metric 'ci_data_used_percent 85' ci-disk

# Just below the threshold stays light.
: > "$CALLS"
DF_PCT=79 bash "$temporary/cleanup"
test "$(wc -l < "$CALLS")" -eq 4

# A failing prune is reported, and the others still run.
: > "$CALLS"
if FAIL_ON='image prune' bash "$temporary/cleanup"; then exit 1; fi
test "$(wc -l < "$CALLS")" -eq 4
metric 'ci_cleanup_success 0' ci-cleanup
metric 'ci_data_used_percent 42' ci-disk
echo 'PASS: prunes while busy, pressure prune, failure metric and disk metric.'
