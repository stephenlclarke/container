"""Credentials must never reach a Bazel client or its recorded environment."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from bazel_environment import BUILD_PATH, BUILD_TEMP, bazel_environment
from fork_benchmark import BAZEL, Runner, output
from runtime_benchmark import build_environment


class BazelEnvironmentTests(unittest.TestCase):
    def test_allowlist_preserves_inputs_without_mutation_or_inventing_ci(self):
        source = dict(HOME='/home/test', DEVELOPER_DIR='/Xcode', GIT_COMMIT='abc',
                      TZ='UTC', SONAR_TOKEN='synthetic', unremarkable='synthetic',
                      DYLD_INSERT_LIBRARIES='/tracer', PATH='/unexpected', TMPDIR='/unexpected')
        before = source.copy()
        self.assertEqual(bazel_environment(source), dict(HOME='/home/test', DEVELOPER_DIR='/Xcode',
                         GIT_COMMIT='abc', TZ='UTC', PATH=BUILD_PATH,
                         TMPDIR=BUILD_TEMP, TMP=BUILD_TEMP, TEMP=BUILD_TEMP))
        self.assertEqual(source, before)
        self.assertEqual(bazel_environment(dict(source, CI='1'))['CI'], '1')

    def test_runtime_and_discovery_boundaries_filter_their_environments(self):
        source = dict(HOME='/home/test', SONAR_TOKEN='synthetic', unremarkable='synthetic')
        with patch.dict(os.environ, source, clear=True):
            self.assertEqual(build_environment(), bazel_environment(source))
        with patch('fork_benchmark.subprocess.check_output', return_value='root') as command:
            output([str(BAZEL), 'info'], env=source)
            self.assertEqual(command.call_args.kwargs['env'], bazel_environment(source))
            self.assertEqual(command.call_args.kwargs['timeout'], 60)

    def test_runner_filters_only_bazel_and_keeps_explicit_tracing_and_test_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = root / 'bazel-probe'
            probe.write_text('#!' + sys.executable + '\nimport json,os,sys\n'
                             'print(json.dumps({"env":dict(os.environ),"args":sys.argv[1:]}))\n')
            probe.chmod(0o700)
            runner = Runner(root, root)
            runner.env = dict(HOME=directory, PATH=BUILD_PATH, SONAR_TOKEN='synthetic', unremarkable='synthetic')
            arguments = ['--action_env=CODEQL_TRACER_CONFIGURATION=/tracing',
                         '--repo_env=CODEQL_TRACER_CONFIGURATION=',
                         '--test_env=LLVM_PROFILE_FILE=/coverage/%p.profraw']
            with patch('fork_benchmark.BAZEL', probe):
                row = runner.run('probe', 'fork', 'bazel', 0, [str(probe), *arguments], root)
            captured = json.loads(Path(row['log']).read_text())
            self.assertNotIn('SONAR_TOKEN', captured['env'])
            self.assertNotIn('unremarkable', captured['env'])
            self.assertEqual(captured['args'], arguments)
            row = runner.run('probe', 'fork', 'quality', 0, [str(probe)], root)
            self.assertEqual(json.loads(Path(row['log']).read_text())['env']['SONAR_TOKEN'], 'synthetic')

    def test_shell_exec_wrapper_uses_same_boundary(self):
        script = Path(__file__).with_name('bazel_environment.py')
        source = dict(HOME='/home/test', PATH=BUILD_PATH, SONAR_TOKEN='synthetic', unremarkable='synthetic')
        captured = json.loads(subprocess.check_output(
            [sys.executable, str(script), sys.executable, '-c',
             'import json,os; print(json.dumps(dict(os.environ)))'], env=source, text=True, timeout=5))
        self.assertNotIn('SONAR_TOKEN', captured)
        self.assertNotIn('unremarkable', captured)
        self.assertEqual(captured['PATH'], BUILD_PATH)


if __name__ == '__main__':
    unittest.main()
