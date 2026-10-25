import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / 'ansible/roles/proxmox-monitoring/files/proxmox-health.py'
SPEC = importlib.util.spec_from_file_location('proxmox_health', SCRIPT)
health = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(health)


class DiskHealthTests(unittest.TestCase):
    def test_health_given_historical_crc_expect_no_false_alarm(self):
        document = {'smart_status': {'passed': True}, 'temperature': {'current': 35},
                    'ata_smart_attributes': {'table': [{'id': 199, 'raw': {'value': 3}}]}}
        alerts, values = health.evaluate_disk(document, label='disk', previous_crc=None, temperature_limit=50)
        self.assertEqual(alerts, [])
        self.assertEqual(values['online'], 1)
        self.assertEqual(values['crc_errors_total'], 3)
        alerts, _ = health.evaluate_disk(document, label='disk', previous_crc=2, temperature_limit=50)
        self.assertIn('disk: SATA CRC error count increased', alerts)

    def test_health_given_smart_query_failure_expect_offline(self):
        alerts, values = health.evaluate_disk({'smartctl': {'exit_status': 2}}, label='disk', previous_crc=3, temperature_limit=50)
        self.assertEqual(values['online'], 0)
        self.assertTrue(alerts)

    def test_health_given_bad_sector_and_heat_expect_both_alerts(self):
        document = {'smart_status': {'passed': True}, 'temperature': {'current': 55},
                    'ata_smart_attributes': {'table': [{'id': 197, 'raw': {'value': 8}}]}}
        alerts, _ = health.evaluate_disk(document, label='disk', previous_crc=None, temperature_limit=50)
        self.assertIn('disk: pending_sectors=8', alerts)
        self.assertIn('disk: temperature >= 50 C', alerts)

    def test_collection_given_missing_disk_expect_fault_and_preserved_crc(self):
        def read_fixture(arguments):
            if Path(arguments[0]).name == 'smartctl':
                raise subprocess.TimeoutExpired('smartctl', 30)
            if Path(arguments[0]).name == 'pvesh':
                return []
            return {'report': [{'lv': []}]}

        with patch.object(health, 'run_json', side_effect=read_fixture), patch.object(health.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')):
            alerts, metrics, state = health.collect_health({'disks': ['/dev/disk'], 'storages': ['pool']}, {'crc': {'disk': 3}}, 1000)
        self.assertIn('homelab_disk_online{disk="disk"} 0', metrics)
        self.assertIn('pool: storage pool unavailable', alerts)
        self.assertEqual(state['crc']['disk'], 3)

    def test_notification_given_same_fault_expect_suppression_and_reminder(self):
        state = {'notified_alerts': ['fault'], 'notified_at': 100}
        self.assertFalse(health.is_notification_due(['fault'], state, 200))
        self.assertTrue(health.is_notification_due(['fault'], state, 21700))
        self.assertTrue(health.is_notification_due([], state, 200))
        self.assertFalse(health.is_notification_due([], {}, 200))

    def test_notification_given_delivery_failure_expect_retry_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({'disks': ['disk'], 'webhook': 'unused'}))
            state_path = root / 'state.json'
            with (
                patch.object(health, 'K_CONFIG', config),
                patch.object(health, 'K_STATE', state_path),
                patch.object(health, 'K_METRICS', root / 'metrics.prom'),
                patch.object(health, 'K_LOCK', root / 'lock'),
                patch.object(health, 'collect_health', return_value=(['fault'], 'metric 1\n', {'crc': {'disk': 3}})),
                patch.object(health, 'publish_discord', side_effect=RuntimeError('delivery failed')),
                patch.object(health.argparse.ArgumentParser, 'parse_args', return_value=type('Arguments', (), {'test_notification': False})()),
            ):
                with self.assertRaises(SystemExit):
                    health.main()
            state = json.loads(state_path.read_text())
            self.assertNotIn('notified_alerts', state)
            self.assertTrue(health.is_notification_due(['fault'], state, 200))


if __name__ == '__main__':
    unittest.main()
