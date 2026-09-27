"""Verify package-relative fixtures, source paths, arguments and exit status."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).with_name("test_runner.sh").resolve()


class TestRunnerTests(unittest.TestCase):
    def check_workspace(self, label, package, exit_code):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runfiles = root / "runfiles with spaces"
            (runfiles / package / "Tests").mkdir(parents=True)
            (runfiles / package / "Tests/fixture").write_text("fixture")
            scratch = root / "scratch"
            scratch.mkdir()
            binary = root / "test binary"
            binary.write_text("#!/bin/bash\nset -eu\n"
                              'test "$(cat Tests/fixture)" = fixture\n'
                              f'test "$(cat external/{package}/Tests/fixture)" = fixture\n'
                              'test "$1" = "argument with spaces"\n'
                              'test "$TMPDIR" = "$TEST_TMPDIR/"\n'
                              'test "$0" = "$TEST_TMPDIR/executable/test binary"\n'
                              f'exit {exit_code}\n')
            binary.chmod(0o755)
            env = dict(os.environ, TEST_TARGET=label, TEST_SRCDIR=str(runfiles), TEST_TMPDIR=str(scratch))
            result = subprocess.run([str(RUNNER), str(binary), "argument with spaces"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, exit_code, result.stderr)
            self.assertEqual((runfiles / package / "Tests/fixture").read_text(), "fixture")
            self.assertEqual(binary.read_bytes(), (scratch / "executable/test binary").read_bytes())

    def test_canonical_external_package(self):
        self.check_workspace("@@extension+package//:tests", "extension+package", 0)

    def test_apparent_external_package_and_failure(self):
        self.check_workspace("@dependency//:tests", "dependency", 7)

    def test_main_workspace(self):
        self.check_workspace("//:tests", "_main", 0)


if __name__ == "__main__":
    unittest.main()
