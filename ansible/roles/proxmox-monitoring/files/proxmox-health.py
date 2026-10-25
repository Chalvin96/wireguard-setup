#!/usr/bin/python3
"""Check configured disks and storage; publish metrics and Discord transitions."""

import argparse
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

K_CONFIG = Path('/etc/proxmox-health.json')
K_STATE = Path('/var/lib/proxmox-health/state.json')
K_METRICS = Path('/var/lib/prometheus/node-exporter/proxmox-health.prom')
K_LOCK = Path('/run/lock/proxmox-health.lock')
K_KERNEL_ERROR = re.compile(r'I/O error|Buffer I/O|ata\d.*(?:failed|exception|SError|link is slow)', re.I)


def run_json(arguments: list[str]) -> dict | list:
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=30, check=False)
    if result.returncode and Path(arguments[0]).name != 'smartctl':
        raise RuntimeError(f'{arguments[0]} exited {result.returncode}')
    return json.loads(result.stdout)


def render_metric(name: str, value: float, **labels: str) -> str:
    suffix = ','.join(f'{key}={json.dumps(label)}' for key, label in labels.items())
    return f'{name}{{{suffix}}} {value}\n' if labels else f'{name} {value}\n'


def evaluate_disk(document: dict, *, label: str, previous_crc: int | None, temperature_limit: int) -> tuple[list[str], dict]:
    attributes = {
        entry['id']: entry.get('raw', {}).get('value', 0)
        for entry in document.get('ata_smart_attributes', {}).get('table', [])
    }
    readable = not (document.get('smartctl', {}).get('exit_status', 0) & 7)
    healthy = document.get('smart_status', {}).get('passed') is True
    values = {
        'online': int(readable),
        'smart_ok': int(readable and healthy),
        'reallocated_sectors': attributes.get(5, 0),
        'pending_sectors': attributes.get(197, 0),
        'uncorrectable_sectors': attributes.get(198, 0),
        'crc_errors_total': attributes.get(199, 0),
    }
    alerts = []
    if not readable:
        alerts.append(f'{label}: SMART query failed or disk is inaccessible')
    elif not healthy:
        alerts.append(f'{label}: SMART health failed or unavailable')
    for name in ('reallocated_sectors', 'pending_sectors', 'uncorrectable_sectors'):
        if values[name] > 0:
            alerts.append(f'{label}: {name}={values[name]}')
    temperature = document.get('temperature', {}).get('current')
    if temperature is not None:
        values['temperature_celsius'] = temperature
        if temperature >= temperature_limit:
            alerts.append(f'{label}: temperature >= {temperature_limit} C')
    if previous_crc is not None and values['crc_errors_total'] > previous_crc:
        alerts.append(f'{label}: SATA CRC error count increased')
    return alerts, values


def collect_health(config: dict, previous: dict, now: int) -> tuple[list[str], str, dict]:
    alerts, metrics = [], []
    current = dict(previous)
    current['crc'] = dict(previous.get('crc', {}))
    for device in config['disks']:
        label = Path(device).name
        try:
            document = run_json(['/usr/sbin/smartctl', '-a', '-j', device])
            findings, values = evaluate_disk(
                document, label=label, previous_crc=current['crc'].get(label),
                temperature_limit=config.get('temperature_limit', 50),
            )
            alerts.extend(findings)
            if values['online']:
                current['crc'][label] = values['crc_errors_total']
        except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
            alerts.append(f'{label}: disk check failed ({type(error).__name__})')
            values = {'online': 0, 'smart_ok': 0}
        metrics.extend(render_metric(f'homelab_disk_{name}', value, disk=label) for name, value in values.items())

    try:
        storages = run_json(['/usr/bin/pvesh', 'get', f'/nodes/{socket.gethostname()}/storage', '--enabled', '1', '--output-format', 'json'])
        by_name = {entry['storage']: entry for entry in storages}
        for name in config['storages']:
            entry = by_name.get(name, {})
            active = int(bool(entry.get('active', 0)))
            metrics.append(render_metric('homelab_storage_active', active, storage=name))
            if not active:
                alerts.append(f'{name}: storage pool unavailable')
            total = entry.get('total', 0)
            if total:
                used = 100 * entry.get('used', 0) / total
                metrics.append(render_metric('homelab_storage_used_percent', used, storage=name))
                if used >= 90:
                    alerts.append(f'{name}: storage usage >= 90%')
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        alerts.append(f'Storage availability check failed ({type(error).__name__})')
        metrics.extend(render_metric('homelab_storage_active', 0, storage=name) for name in config['storages'])

    try:
        volumes = run_json(['/usr/sbin/lvs', '--reportformat', 'json', '-o', 'lv_name,vg_name,lv_attr,data_percent,metadata_percent'])
        for volume in volumes['report'][0]['lv']:
            if volume['lv_attr'].startswith('t'):
                pool = f"{volume['vg_name']}/{volume['lv_name']}"
                for field in ('data_percent', 'metadata_percent'):
                    value = float(volume[field])
                    metrics.append(render_metric(f'homelab_thin_pool_{field}', value, pool=pool))
                    if value >= 85:
                        alerts.append(f'{pool}: {field} >= 85%')
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        alerts.append(f'Thin-pool check failed ({type(error).__name__})')

    try:
        journal = subprocess.run(
            ['/usr/bin/journalctl', '-k', '--since', f"@{previous.get('journal_since', now - 300)}", '--until', f'@{now}', '--no-pager', '-o', 'cat'],
            capture_output=True, text=True, timeout=30, check=True,
        )
        errors = sum(bool(K_KERNEL_ERROR.search(line)) for line in journal.stdout.splitlines())
        current['kernel_errors'] = previous.get('kernel_errors', 0) + errors
        current['journal_since'] = now
        if errors:
            alerts.append('New storage I/O or SATA errors in kernel log')
    except (OSError, subprocess.SubprocessError) as error:
        alerts.append(f'Kernel log check failed ({type(error).__name__})')
    metrics.append(render_metric('homelab_storage_kernel_errors_total', current.get('kernel_errors', 0)))
    metrics.append(render_metric('homelab_health_last_run_timestamp_seconds', now))
    metrics.append(render_metric('homelab_health_issue_count', len(alerts)))
    return sorted(alerts), ''.join(metrics), current


def publish_discord(webhook: str, message: str) -> None:
    payload = json.dumps({'content': message[:1900], 'allowed_mentions': {'parse': []}}).encode()
    request = urllib.request.Request(
        webhook, data=payload, method='POST',
        headers={'Content-Type': 'application/json', 'User-Agent': 'Homelab-Proxmox-Health/1.0'},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status not in (200, 204):
                raise RuntimeError(f'Discord HTTP {response.status}')
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'Discord HTTP {error.code}') from None
    except OSError:
        raise RuntimeError('Discord connection failed') from None


def is_notification_due(alerts: list[str], previous: dict, now: int) -> bool:
    old_alerts = previous.get('notified_alerts', [])
    return alerts != old_alerts or bool(alerts and now - previous.get('notified_at', 0) >= 21600)


def write_atomic(path: Path, text: str, mode: int) -> None:
    temporary = path.with_suffix('.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(descriptor, 'w') as output:
        output.write(text)
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test-notification', action='store_true')
    arguments = parser.parse_args()
    config = json.loads(K_CONFIG.read_text())
    if arguments.test_notification:
        publish_discord(config['webhook'], f'TEST: Proxmox SATA cron notifications from {socket.gethostname()} work.')
        print('Discord test delivered')
        return
    with K_LOCK.open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        previous = json.loads(K_STATE.read_text()) if K_STATE.exists() else {}
        now = int(time.time())
        alerts, metrics, current = collect_health(config, previous, now)
        write_atomic(K_METRICS, metrics, 0o644)
        failed = False
        if is_notification_due(alerts, previous, now):
            message = f'PROXMOX ALERT ({socket.gethostname()}):\n' + '\n'.join(alerts) if alerts else f'PROXMOX RECOVERY ({socket.gethostname()}): no current disk/storage faults or new kernel I/O errors detected.'
            try:
                publish_discord(config['webhook'], message)
                current.update(notified_alerts=alerts, notified_at=now)
            except RuntimeError as error:
                print(str(error), file=sys.stderr)
                failed = True
        write_atomic(K_STATE, json.dumps(current), 0o600)
        print(f'Checked {len(config["disks"])} SATA disks: {len(alerts)} issues')
        if failed:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
