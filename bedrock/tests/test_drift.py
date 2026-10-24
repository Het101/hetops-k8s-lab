"""The drift check's parser: python3 -m unittest discover -s tests (from bedrock/)."""
import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

BEDROCK = Path(__file__).resolve().parent.parent
path = str(BEDROCK / "roles/drift/files/bedrock-drift")
loader = importlib.machinery.SourceFileLoader("bedrock_drift", path)
spec = importlib.util.spec_from_loader("bedrock_drift", loader)
drift = importlib.util.module_from_spec(spec)
loader.exec_module(drift)


def task(name, **result):
    return {"task": {"name": name}, "hosts": {"my-workspace": result}}


class Differences(unittest.TestCase):
    def test_changed_and_failed_tasks_with_their_roles(self):
        data = {"plays": [{"tasks": [
            task("Gathering Facts", changed=False),
            task("common : SSH uses Bedrock's settings", changed=True),
            task("kubernetes : Apt holds the runtime and the kube packages", changed=False),
            task("audit : The running API server has every audit flag", failed=True),
            task("drift : The drift check runs nightly", skipped=True),
        ]}]}
        changed, failed = drift.differences(data)
        self.assertEqual(changed, [{"role": "common", "task": "SSH uses Bedrock's settings"}])
        self.assertEqual(failed, [{"role": "audit", "task": "The running API server has every audit flag"}])

    def test_a_clean_run_has_nothing_to_say(self):
        self.assertEqual(drift.differences({"plays": [{"tasks": [task("base : x", changed=False)]}]}), ([], []))

    def test_a_task_without_a_role(self):
        changed, _ = drift.differences({"plays": [{"tasks": [task("Some play task", changed=True)]}]})
        self.assertEqual(changed, [{"role": "", "task": "Some play task"}])


class Fleet(unittest.TestCase):
    """25 Oct: the check runs from the control node across every server; each is reported on its own."""

    def test_each_server_is_reported_on_its_own(self):
        data = {"plays": [{"tasks": [
            {"task": {"name": "common : SSH uses Bedrock's settings"},
             "hosts": {"my-workspace": {"changed": False}, "vm2": {"changed": True}}},
            {"task": {"name": "audit : The running API server has every audit flag"},
             "hosts": {"my-workspace": {"failed": True}}},
        ]}], "stats": {"my-workspace": {}, "vm2": {}}}
        hosts = drift.per_host(data)
        self.assertEqual(hosts["vm2"], ([{"role": "common", "task": "SSH uses Bedrock's settings"}], []))
        self.assertEqual(hosts["my-workspace"], ([], [{"role": "audit", "task": "The running API server has every audit flag"}]))

    def test_an_unreachable_server_is_a_failure_not_a_match(self):
        data = {"plays": [{"tasks": [{"task": {"name": "Gathering Facts"}, "hosts": {"vm2": {"unreachable": True}}}]}],
                "stats": {"vm2": {}}}
        self.assertEqual(drift.per_host(data)["vm2"], ([], [{"role": "bedrock", "task": "the server could not be reached"}]))

    def test_a_clean_server_is_still_listed_so_its_state_can_clear(self):
        data = {"plays": [{"tasks": [task("common : x", changed=False)]}], "stats": {"my-workspace": {}, "vm2": {}}}
        self.assertEqual(drift.per_host(data), {"my-workspace": ([], []), "vm2": ([], [])})


class Handlers(unittest.TestCase):
    def test_a_handler_that_would_run_is_not_a_second_change(self):
        data = {"plays": [{"tasks": [
            task("common : SSH uses Bedrock's settings", changed=True),
            task("common : Reload SSH", changed=True),
        ]}]}
        changed, _ = drift.differences(data, drift.handlers(BEDROCK))
        self.assertEqual(changed, [{"role": "common", "task": "SSH uses Bedrock's settings"}])

    def test_the_real_handler_files_are_read(self):
        names = drift.handlers(BEDROCK)
        for expected in [("common", "Reload SSH"), ("audit", "Restart the API server"), ("kubernetes", "Restart containerd")]:
            self.assertIn(expected, names)


if __name__ == "__main__":
    unittest.main()
