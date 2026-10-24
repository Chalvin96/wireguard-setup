import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


class MigrationRecoveryTests(unittest.TestCase):
    def setUp(self):  # noqa: UME-PY004 - unittest lifecycle hook
        self.root = Path(__file__).resolve().parents[1]
        self.play = yaml.safe_load((self.root / "ansible/migrate-rootless.yml").read_text())[0]
        self.preparation = self.play["tasks"][0]

    def test_environment_given_legacy_or_managed_flags_expect_only_exact_transition(self):
        task = next(
            item for item in self.preparation["block"]
            if item["name"] == "Refuse unrelated Penpot configuration changes during migration"
        )
        variables = {
            "penpot_version": "fixture-version",
            "penpot_flags": "enable-login-with-password",
            "penpot_public_uri": "http://example.invalid",
            "vault_penpot_secret_key": "fixture-only",
            "vault_penpot_postgres_password": "fixture-only",
        }
        expected = (self.root / "ansible/roles/penpot/templates/env.j2").read_text()
        for name, value in variables.items():
            expected = expected.replace("{{ " + name + " }}", value)
        cases = [
            ("managed", expected, 0),
            ("legacy", expected.replace(" enable-mcp\n", "\n"), 0),
            ("changed-secret", expected.replace("PENPOT_SECRET_KEY=fixture-only", "PENPOT_SECRET_KEY=different-fixture"), 2),
            ("changed-uri", expected.replace("example.invalid", "different.invalid"), 2),
        ]
        for name, content, exit_code in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                template = temporary / "roles/penpot/templates/env.j2"
                template.parent.mkdir(parents=True)
                template.write_text((self.root / "ansible/roles/penpot/templates/env.j2").read_text())
                fixture = variables | {"rootless_existing_env": {"content": base64.b64encode(content.encode()).decode()}}
                result = self._run_play(temporary, {"vars": fixture, "tasks": [task]})
                self.assertEqual(result.returncode, exit_code, result.stdout)

    def test_preparation_given_later_failure_expect_original_runner_states(self):
        stages = [
            "Configure rootless Docker for migration",
            "Refuse unrelated Penpot configuration changes during migration",
            "Preserve existing service configuration for rollback",
        ]
        for stage in stages:
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                state_file = temporary / "states.json"
                original = {"actions-runner@alpha.service": "active", "actions-runner@beta.service": "inactive"}
                state_file.write_text(json.dumps(original))
                library = temporary / "library"
                library.mkdir()
                (library / "mock_systemd.py").write_text('''
import json
from ansible.module_utils.basic import AnsibleModule
module = AnsibleModule(argument_spec={
    "name": {"required": True}, "state": {}, "state_file": {"required": True}
})
path = module.params["state_file"]
with open(path) as stream:
    states = json.load(stream)
name = module.params["name"]
if not name.endswith(".service"):
    name += ".service"
before = states[name]
if module.params["state"]:
    states[name] = "active" if module.params["state"] == "started" else "inactive"
    with open(path, "w") as stream:
        json.dump(states, stream)
module.exit_json(changed=before != states[name], status={"Id": name, "ActiveState": states[name]})
''')
                query = copy.deepcopy(next(
                    task for task in self.play["pre_tasks"]
                    if task["name"] == "Record original runner service state"
                ))
                self._mock_systemd(query, state_file)
                preparation = copy.deepcopy(self.preparation)
                preparation["block"] = [
                    task if "ansible.builtin.systemd" in task else {
                        "name": task["name"],
                        "ansible.builtin.fail" if task["name"] == stage else "ansible.builtin.debug": {"msg": "fixture"},
                    }
                    for task in preparation["block"]
                ]
                for task in preparation["block"] + preparation["rescue"]:
                    if "ansible.builtin.systemd" in task:
                        self._mock_systemd(task, state_file)
                    if "ansible.builtin.command" in task:
                        task.pop("ansible.builtin.command")
                        task.pop("become", None)
                        task.pop("become_user", None)
                        task["ansible.builtin.debug"] = {"msg": "context restored"}
                result = self._run_play(temporary, {
                    "vars": {"github_runner_repos": [{"repo": "alpha"}, {"repo": "beta"}]},
                    "tasks": [query, preparation],
                })
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("Report migration preparation failure", result.stdout)
                self.assertEqual(json.loads(state_file.read_text()), original, result.stdout)

    def _mock_systemd(self, task, state_file):
        task["mock_systemd"] = task.pop("ansible.builtin.systemd") | {"state_file": str(state_file)}

    def _run_play(self, directory, play):
        path = directory / "test.yml"
        path.write_text(yaml.safe_dump([{"hosts": "localhost", "gather_facts": False} | play]))
        config = directory / "ansible.cfg"
        config.write_text("[defaults]\nretry_files_enabled=False\nhost_key_checking=False\n")
        return subprocess.run(
            [str(Path(sys.executable).with_name("ansible-playbook")), "-i", "localhost,", "-c", "local", str(path)],
            cwd=directory,
            env=os.environ | {"ANSIBLE_CONFIG": str(config)},
            capture_output=True, text=True, timeout=60,
        )


if __name__ == "__main__":
    unittest.main()
