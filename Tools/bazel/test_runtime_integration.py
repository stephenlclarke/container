"""Retain real layer results and reject green runs which selected no test cases."""

from pathlib import Path
import os
import subprocess
import shutil
import tempfile
import sys
import time
import unittest

from runtime_integration import owned_cli_processes, retain_layer_reports, stop_test_children, test_filter


class IntegrationReportsTests(unittest.TestCase):
    def test_cleanup_stops_only_recorded_children(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path('/bin/sleep')
            records = Path(directory)
            wrapper = Path(__file__).with_name('integration_cli.py')
            owned = subprocess.Popen([sys.executable, str(wrapper), '60'], start_new_session=True,
                                     env=dict(os.environ, CLITEST_REAL_CLI=str(executable),
                                              CLITEST_PROCESS_DIRECTORY=directory, TZ='Pacific/Honolulu'))
            unrelated = subprocess.Popen([str(executable), '60'], start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not owned_cli_processes(executable, records) and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertEqual(set(owned_cli_processes(executable, records)), {owned.pid})
                self.assertEqual(stop_test_children(executable, records), [owned.pid])
                self.assertIsNone(unrelated.poll())
            finally:
                for process in (owned, unrelated):
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)

    def test_cleanup_recognizes_cli_exec_into_a_known_plugin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / 'bin/container'
            plugin = root / 'libexec/container/plugins/k8s/bin/k8s'
            executable.parent.mkdir()
            plugin.parent.mkdir(parents=True)
            shutil.copyfile('/bin/sleep', plugin)
            plugin.chmod(0o755)
            executable.write_text('#!/bin/sh\nexec "' + str(plugin) + '" "$@"\n')
            executable.chmod(0o755)
            records = root / 'records'
            records.mkdir()
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('integration_cli.py')), '60'],
                                       start_new_session=True, env=dict(os.environ,
                                           CLITEST_REAL_CLI=str(executable), CLITEST_PROCESS_DIRECTORY=str(records)))
            try:
                deadline = time.monotonic() + 5
                while not owned_cli_processes(executable, records) and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertEqual(stop_test_children(executable, records), [process.pid])
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)

    def test_empty_and_skipped_only_results_do_not_qualify_a_layer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prefix = root / 'run'
            reports = root / 'run.events.tests'
            reports.mkdir()
            log = root / 'command.log'
            log.write_text('Evidence: ' + str(prefix) + '.log\n')
            xml = reports / 'test.xml'
            xml.write_text('<testsuite><testcase name="skip"><skipped/></testcase></testsuite>')
            with self.assertRaisesRegex(RuntimeError, 'no test cases'):
                retain_layer_reports(log, root / 'empty')
            xml.write_text('<testsuite><testcase name="passed"/><testcase name="failed"><failure/></testcase></testsuite>')
            self.assertEqual(retain_layer_reports(log, root / 'executed'), 2)
            self.assertEqual((root / 'executed/test.xml').read_bytes(), xml.read_bytes())

    def test_missing_layer_cannot_silently_select_everything(self):
        with self.assertRaisesRegex(RuntimeError, 'No integration suites'):
            test_filter('Nonexistent')
        self.assertIn('TestCLIVersion', test_filter('System'))
        self.assertNotIn('TestCLIRun', test_filter('System'))


if __name__ == '__main__':
    unittest.main()
