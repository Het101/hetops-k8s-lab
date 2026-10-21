"""The drift check's parser: python3 -m unittest discover -s tests (from bedrock/)."""
import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

path = str(Path(__file__).resolve().parent.parent / "roles/drift/files/bedrock-drift")
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
            task("base : SSH uses Bedrock's settings", changed=True),
            task("kubernetes : Apt holds the runtime and the kube packages", changed=False),
            task("audit : The running API server has every audit flag", failed=True),
            task("drift : The drift check runs nightly", skipped=True),
        ]}]}
        changed, failed = drift.differences(data)
        self.assertEqual(changed, [{"role": "base", "task": "SSH uses Bedrock's settings"}])
        self.assertEqual(failed, [{"role": "audit", "task": "The running API server has every audit flag"}])

    def test_a_clean_run_has_nothing_to_say(self):
        self.assertEqual(drift.differences({"plays": [{"tasks": [task("base : x", changed=False)]}]}), ([], []))

    def test_a_task_without_a_role(self):
        changed, _ = drift.differences({"plays": [{"tasks": [task("Some play task", changed=True)]}]})
        self.assertEqual(changed, [{"role": "", "task": "Some play task"}])


if __name__ == "__main__":
    unittest.main()
