#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/ci/no-work" "$temporary/ci-second/no-work" "$temporary/ci-third/fixture-3/_work" "$temporary/bin" "$temporary/metrics" "$temporary/ci/fixture/_work"
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
(temporary / 'cleanup').write_text(environment.from_string(source).render(
    github_runner_instances=[
        {'name': 'fixture', 'user': 'ci-fixture', 'home': str(temporary / 'ci')},
        {'name': 'no-work', 'user': 'ci-second', 'home': str(temporary / 'ci-second')},
        {'name': 'fixture-3', 'user': 'ci-third', 'home': str(temporary / 'ci-third')},
    ],
    ci_build_cache_budget='5GB', ci_cache_retention_days=14))
PY
cat > "$temporary/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
EOF
cat > "$temporary/bin/id" <<'EOF'
#!/bin/bash
case "$*" in
    *ci-second) echo 998 ;;
    *ci-third) echo 997 ;;
    *) echo 999 ;;
esac
EOF
cat > "$temporary/bin/pgrep" <<'EOF'
#!/bin/bash
if [[ -n "${BUSY_UID:-}" ]]; then
    [[ " $* " == *" -u $BUSY_UID "* ]] && exit 0
    exit 1
fi
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

# A job on any one instance's account must skip cleanup for all of them.
: > "$CALLS"
BUSY_UID=997 bash "$temporary/cleanup"
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
work="$temporary/ci/fixture/_work"
mkdir -p "$work/stale" "$work/fresh" "$work/_actions" "$work/.pnpm-store/old" "$temporary/ci/.cache"
touch "$work/stale/file" "$work/fresh/file" "$work/_actions/file" "$work/.pnpm-store/old/stale" "$work/.pnpm-store/fresh" "$temporary/ci/.cache/stale" "$temporary/ci/.cache/fresh"
mkdir -p "$temporary/ci-third/fixture-3/_work/stale" "$temporary/ci-third/fixture-3/_work/fresh"
touch -d '30 days ago' "$temporary/ci-third/fixture-3/_work/stale"
touch -d '30 days ago' "$work/stale" "$work/.pnpm-store/old/stale" "$temporary/ci/.cache/stale"
touch -d '30 days ago' -a "$work/.pnpm-store/old/stale" "$temporary/ci/.cache/stale"
mkdir -p "$temporary/ci/_tool/trivy-fixture/fanal" "$temporary/ci/_tool/trivy-new" "$temporary/ci/_tool/node"
touch "$temporary/ci/_tool/trivy-fixture/fanal/disposable" "$temporary/ci/_tool/node/keep"
touch -d '30 days ago' "$temporary/ci/_tool/trivy-fixture"
USED_BYTES=40000000000 bash "$temporary/cleanup"
test ! -e "$work/stale"
test -e "$work/fresh/file"
test ! -e "$temporary/ci-third/fixture-3/_work/stale"
test -e "$temporary/ci-third/fixture-3/_work/fresh"
test -e "$work/_actions/file"
test ! -e "$work/.pnpm-store/old"
test -e "$work/.pnpm-store/fresh"
test ! -e "$temporary/ci/.cache/stale"
test -e "$temporary/ci/.cache/fresh"
test ! -e "$temporary/ci/_tool/trivy-fixture"
test -e "$temporary/ci/_tool/trivy-new"
test -e "$temporary/ci/_tool/node/keep"
! grep -q 'image prune.*--all' "$CALLS"
grep -q 'image prune --force$' "$CALLS"
grep -q 'volume rm buildx_buildkit_old_state$' "$CALLS"
! grep -q 'volume rm keep-named-data' "$CALLS"
grep -q 'buildx prune --builder default --force --max-used-space 5GB$' "$CALLS"
test "$(grep -c 'buildx prune --builder default ' "$CALLS")" -eq 3
! grep -q 'buildx prune --builder rootless ' "$CALLS"
grep -q 'buildx prune --builder persistent --force --max-used-space 5GB$' "$CALLS"
test "$(grep -c 'buildx prune --builder persistent ' "$CALLS")" -eq 3
grep -q '^systemctl thaw ' "$CALLS"
grep -qx 'ci_cleanup_success 1' "$temporary/metrics/ci-cleanup.prom"
! grep '^runuser ' "$CALLS" | grep -v -E -- '-u ci-(fixture|second|third) -- docker --host unix:///run/user/(999|998|997)/docker.sock'
echo 'PASS: per-instance daemons, busy/error skips, failure thaw, scoped cache pruning, age-based retention and cleanup metrics.'
