#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/metrics" "$temporary/ci/fixture/_work"
python3 - "$repo_root" "$temporary" <<'PY'
import shlex
import sys
from pathlib import Path
from jinja2 import Environment
root, temporary = map(Path, sys.argv[1:])
environment = Environment()
environment.filters['quote'] = shlex.quote
source = (root / 'ansible/roles/ci-maintenance/templates/ci-cleanup.sh.j2').read_text()
source = source.replace('/run/lock/ci-cleanup.lock', str(temporary / 'lock'))
source = source.replace('/var/lib/prometheus/node-exporter', str(temporary / 'metrics'))
(temporary / 'cleanup').write_text(environment.from_string(source).render(
    github_runner_user='ci-fixture', github_runner_home=str(temporary / 'ci'),
    github_runner_repos=[{'repo': 'fixture'}]))
PY
cat > "$temporary/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
EOF
cat > "$temporary/bin/id" <<'EOF'
#!/bin/bash
echo 999
EOF
cat > "$temporary/bin/pgrep" <<'EOF'
#!/bin/bash
exit "${JOB_STATUS:-1}"
EOF
cat > "$temporary/bin/df" <<'EOF'
#!/bin/bash
echo "${USED_BYTES:-10000000000}"
EOF
cat > "$temporary/bin/runuser" <<'EOF'
#!/bin/bash
echo "runuser $*" >> "$CALLS"
if [[ "${DOCKER_FAIL:-0}" == 1 ]]; then exit 17; fi
case "$*" in
    *'volume ls '*) printf 'buildx_buildkit_old_state\nkeep-named-data\n' ;;
    *'buildx ls '*) printf '{"Name":"default","Driver":"docker"}\n{"Name":"rootless","Driver":"docker"}\n{"Name":"persistent","Driver":"docker-container"}\n{"Name":"persistent","Driver":"docker-container"}\n' ;;
esac
EOF
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH" CALLS="$temporary/calls"
path_setup=$(sed -n '/^export PATH=/p' "$temporary/cleanup")
env -i PATH=/usr/bin:/bin bash -c "$path_setup; command -v runuser" >/dev/null

JOB_STATUS=0 bash "$temporary/cleanup"
grep -q '^systemctl freeze ' "$CALLS"
grep -q '^systemctl thaw ' "$CALLS"
! grep -q '^runuser ' "$CALLS"

: > "$CALLS"
if JOB_STATUS=2 bash "$temporary/cleanup"; then exit 1; fi
! grep -q '^runuser ' "$CALLS"
grep -q '^systemctl thaw ' "$CALLS"

: > "$CALLS"
if DOCKER_FAIL=1 bash "$temporary/cleanup"; then exit 1; fi
grep -q '^systemctl thaw ' "$CALLS"
grep -qx 'ci_cleanup_success 0' "$temporary/metrics/ci-cleanup.prom"

: > "$CALLS"
touch "$temporary/ci/fixture/_work/disposable"
mkdir -p "$temporary/ci/_tool/trivy-fixture/fanal" "$temporary/ci/_tool/node"
touch "$temporary/ci/_tool/trivy-fixture/fanal/disposable" "$temporary/ci/_tool/node/keep"
USED_BYTES=40000000000 bash "$temporary/cleanup"
test ! -e "$temporary/ci/fixture/_work"
test ! -e "$temporary/ci/_tool/trivy-fixture"
test -e "$temporary/ci/_tool/node/keep"
grep -q 'volume rm buildx_buildkit_old_state$' "$CALLS"
! grep -q 'volume rm keep-named-data' "$CALLS"
grep -q 'buildx prune --builder default --force --max-used-space 2GB$' "$CALLS"
test "$(grep -c 'buildx prune --builder default ' "$CALLS")" -eq 1
! grep -q 'buildx prune --builder rootless ' "$CALLS"
grep -q 'buildx prune --builder persistent --force --max-used-space 2GB$' "$CALLS"
test "$(grep -c 'buildx prune --builder persistent ' "$CALLS")" -eq 1
grep -q '^systemctl thaw ' "$CALLS"
grep -qx 'ci_cleanup_success 1' "$temporary/metrics/ci-cleanup.prom"
! grep '^runuser ' "$CALLS" | grep -v -- '-u ci-fixture -- docker --host unix:///run/user/999/docker.sock'
echo 'PASS: busy/error skips, failure thaw, scoped cache pruning, workspace budget and cleanup metrics.'
