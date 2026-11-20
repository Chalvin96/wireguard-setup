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
(temporary / 'cleanup').write_text(environment.from_string(source).render(github_runner_home='/ci home'))
PY
cat > "$temporary/bin/docker" <<'EOF2'
#!/bin/bash
echo "docker $*" >> "$CALLS"
[[ "$*" != *"${FAIL_ON:-never}"* ]]
EOF2
cat > "$temporary/bin/pgrep" <<'EOF2'
#!/bin/bash
[[ "$*" == '-x Runner.Worker' ]] || exit 2
exit "${JOB_STATUS:-1}"
EOF2
cat > "$temporary/bin/df" <<'EOF2'
#!/bin/bash
[[ "$*" == '--output=pcent /ci home' ]] || exit 2
printf 'Use%%\n 42%%\n'
EOF2
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH" CALLS="$temporary/calls"
metric() { grep -qx "$1" "$temporary/metrics/$2.prom"; }

# Busy: no prune calls, metrics still written.
: > "$CALLS"
JOB_STATUS=0 bash "$temporary/cleanup"
test ! -s "$CALLS"
metric 'ci_cleanup_success 1' ci-cleanup
grep -q '^ci_cleanup_last_run_timestamp_seconds [0-9]\+$' "$temporary/metrics/ci-cleanup.prom"
metric 'ci_data_used_percent 42' ci-disk

# Idle: exactly the four prunes.
: > "$CALLS"
bash "$temporary/cleanup"
diff - "$CALLS" <<'EOF2'
docker container prune -f --filter until=24h
docker image prune -af --filter until=72h
docker volume prune -af
docker builder prune -af --filter until=72h
EOF2
metric 'ci_cleanup_success 1' ci-cleanup

# A failing prune is reported, and the others still run.
: > "$CALLS"
if FAIL_ON='image prune' bash "$temporary/cleanup"; then exit 1; fi
test "$(wc -l < "$CALLS")" -eq 4
metric 'ci_cleanup_success 0' ci-cleanup
metric 'ci_data_used_percent 42' ci-disk
echo 'PASS: busy skip, idle prunes, failure metric and disk metric.'
