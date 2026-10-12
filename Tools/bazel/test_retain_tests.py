"""Regression tests for retaining test evidence independently of the SSD cache."""

import json
from pathlib import Path
import tempfile
import unittest

from retain_tests import retain


class RetainTests(unittest.TestCase):
    def test_preserves_separate_attempts_and_non_ascii_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "report with spaces é.xml"
            source.write_text("<testsuite tests='75' failures='0'/>")
            events = root / "run.json"
            rows = [{"started": {}}]
            for attempt in [1, 2]:
                rows.append({"id": {"testResult": {"label": "//:tests", "attempt": attempt}},
                             "testResult": {"status": "PASSED", "testActionOutput": [
                                 {"uri": source.as_uri()}, {"uri": "bytestream://unavailable"}]}})
            events.write_text("\n".join(json.dumps(row) for row in rows))
            retain(events)
            index = json.loads((root / "run.tests/index.json").read_text())
            self.assertEqual(len(index), 2)
            for attempt, entry in enumerate(index):
                self.assertEqual(entry["status"], "PASSED")
                self.assertEqual(entry["files"], [f"{attempt}/{source.name}"])
                self.assertEqual((root / "run.tests" / entry["files"][0]).read_text(), source.read_text())

    def test_build_with_no_tests_retains_empty_index(self):
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "build.json"
            events.write_text('{"finished": {}}\n')
            retain(events)
            self.assertEqual(json.loads(events.with_suffix(".tests").joinpath("index.json").read_text()), [])

    def test_missing_report_fails_instead_of_claiming_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "run.json"
            events.write_text(json.dumps({"id": {}, "testResult": {"status": "FAILED", "testActionOutput": [
                {"uri": (Path(directory) / "missing.xml").as_uri()}]}}))
            with self.assertRaises(FileNotFoundError):
                retain(events)


if __name__ == "__main__":
    unittest.main()
