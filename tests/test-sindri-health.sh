#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/metrics"
sed -e 's|{{ tools_ip }}|127.0.0.1|g' \
    -e "s|/var/lib/prometheus/node-exporter|$test_dir/metrics|g" \
    "$repo_root/ansible/roles/sindri-monitoring/templates/sindri-health.sh.j2" > "$test_dir/health"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '0.005000'
exit "${PROBE_EXIT:-0}"
EOF
cat > "$test_dir/bin/runuser" <<'EOF'
#!/bin/sh
printf '%s\n' "${DATABASE_RESULT:-1}"
exit "${DATABASE_EXIT:-0}"
EOF
cat > "$test_dir/bin/id" <<'EOF'
#!/bin/sh
printf '997\n'
EOF
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"

bash "$test_dir/health"
grep -qx 'sindri_penpot_api_up 1' "$test_dir/metrics/sindri-health.prom"
grep -qx 'sindri_penpot_database_up 1' "$test_dir/metrics/sindri-health.prom"
grep -qx 'sindri_penpot_api_duration_seconds 0.005000' "$test_dir/metrics/sindri-health.prom"

PROBE_EXIT=28 DATABASE_EXIT=1 bash "$test_dir/health"
grep -qx 'sindri_penpot_api_up 0' "$test_dir/metrics/sindri-health.prom"
grep -qx 'sindri_penpot_database_up 0' "$test_dir/metrics/sindri-health.prom"
grep -Eq '^sindri_health_last_run_timestamp_seconds [0-9]+$' "$test_dir/metrics/sindri-health.prom"

DATABASE_RESULT=unexpected bash "$test_dir/health"
grep -qx 'sindri_penpot_database_up 0' "$test_dir/metrics/sindri-health.prom"
test "$(stat -c %a "$test_dir/metrics/sindri-health.prom")" = 644
test "$(find "$test_dir/metrics" -type f | wc -l)" -eq 1
echo 'PASS: healthy probes, HTTP timeout, database failure, invalid SQL output, and atomic readable metrics.'
