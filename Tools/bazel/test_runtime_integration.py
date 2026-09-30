"""Retain real layer results and reject green runs which selected no test cases."""

from pathlib import Path
import json
import os
import re
import signal
import subprocess
import tempfile
import sys
import time
import unittest
from unittest import mock

from runtime_benchmark import RuntimeRunner
import runtime_integration
from runtime_integration import EOFIntegrationRunner, owned_cli_processes, require_commit_cases, require_eof_cases, retain_layer_reports, stop_test_children, test_filter


class IntegrationReportsTests(unittest.TestCase):
    def test_upstream_commit_cases_are_selected_and_reported(self):
        for name in ('testCommitStoppedContainer()', 'testCommitRunningContainer()'):
            self.assertIsNotNone(re.search(test_filter('Containers'), 'TestCLICommitCommand/' + name))
        source = runtime_integration.ROOT / 'Tests/IntegrationTests/Containers/TestCLICommitCommand.swift'
        self.assertIn('struct TestCLICommitCommand', source.read_text())
        with tempfile.TemporaryDirectory() as directory:
            reports = Path(directory)
            xml = reports / 'test.xml'
            expected = ['testCommitStoppedContainer()', 'testCommitRunningContainer()']

            def report(names):
                xml.write_text('<testsuites><testsuite name="IntegrationTests.TestCLICommitCommand">'
                               + ''.join(f'<testcase name="{name}" result="completed"/>' for name in names)
                               + '</testsuite><testsuite name="IntegrationTests.Other">'
                               + '<testcase name="other()" result="completed"/></testsuite></testsuites>')

            report(expected)
            require_commit_cases(reports)
            for invalid in (expected[:-1], [expected[0], 'other()'], [*expected, expected[0]]):
                report(invalid)
                with self.assertRaisesRegex(RuntimeError, 'both upstream cases'):
                    require_commit_cases(reports)
            report(expected)
            xml.write_text(xml.read_text().replace('result="completed"', 'result="skipped"', 1))
            with self.assertRaisesRegex(RuntimeError, 'both upstream cases'):
                require_commit_cases(reports)

    def test_focused_eof_requires_exact_three_completed_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            reports = Path(directory)
            xml = reports / 'test.xml'
            def report(names):
                xml.write_text('<testsuites><testsuite name="IntegrationTests.TestCLIPrimaryInputEOF">'
                               + ''.join(f'<testcase name="{name}" result="completed"/>' for name in names)
                               + '</testsuite></testsuites>')
            expected = ['foregroundDedicatedRunClosesFiniteInput()',
                        'prewarmedDedicatedStartClosesFiniteInput()',
                        'foregroundSharedRunClosesFiniteInput()']
            report(expected)
            require_eof_cases(reports)
            for invalid in (expected[:-1], [*expected[:2], 'unrelated()'], [*expected, expected[0]]):
                report(invalid)
                with self.assertRaisesRegex(RuntimeError, 'all three original cases'):
                    require_eof_cases(reports)
            report(expected)
            xml.write_text(xml.read_text().replace('result="completed"', 'result="skipped"', 1))
            with self.assertRaisesRegex(RuntimeError, 'all three original cases'):
                require_eof_cases(reports)
            report(expected)
            xml.write_text(xml.read_text().replace('</testsuites>',
                '<testsuite name="IntegrationTests.Unrelated"><testcase name="extra()" result="completed"/></testsuite></testsuites>'))
            with self.assertRaisesRegex(RuntimeError, 'all three original cases'):
                require_eof_cases(reports)

    def test_focused_eof_start_enables_debug_without_changing_other_commands(self):
        runner = EOFIntegrationRunner(Path('/unused'), Path('/unused'))
        with mock.patch.object(RuntimeRunner, 'command', return_value={'status': 0}) as command:
            runner.command('fork', 'setup-start', 0, ['system', 'start', '--app-root', '/private/app'])
            self.assertEqual(command.call_args.args[3],
                             ['system', 'start', '--app-root', '/private/app', '--debug'])
            runner.command('fork', 'setup-images', 0, ['image', 'load', '--input', '/archive'])
            self.assertEqual(command.call_args.args[3], ['image', 'load', '--input', '/archive'])
            with self.assertRaisesRegex(RuntimeError, 'unexpected service startup'):
                runner.command('fork', 'setup-start', 0, ['system', 'stop'])

    def test_default_run_layer_starts_with_eof_debug_marker_available(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepared = root / 'prepared'
            prepared.mkdir()
            for name in ('source-inputs.json', 'guest-artifact.json', 'builder-artifact.json'):
                (prepared / name).write_text('{}\n')
            (prepared / 'fork-fingerprint.json').write_text(json.dumps({
                'init_image': 'init', 'builder_image': 'builder', 'kernel_sha256': 'kernel',
            }))
            installs = root / 'installs'
            installs.mkdir()
            (installs / 'benchmark.lock').touch()

            def check_startup(runner, lane):
                runner.command(lane, 'setup-start', 0, ['system', 'start', '--app-root', '/private/app'])
                raise RuntimeError('stop after default startup proof')

            with (mock.patch.object(runtime_integration, 'STATE', root / 'state'),
                  mock.patch.object(runtime_integration, 'INSTALLS', installs),
                  mock.patch.object(runtime_integration, 'verify_prepared'),
                  mock.patch.object(runtime_integration, 'stop_owned'),
                  mock.patch.object(runtime_integration, 'stop_test_children', return_value=[]),
                  mock.patch.object(runtime_integration, 'reset_state', return_value='kernel'),
                  mock.patch.object(runtime_integration, 'start_lane', side_effect=check_startup),
                  mock.patch.object(RuntimeRunner, 'command', return_value={'status': 0}) as command):
                with self.assertRaisesRegex(RuntimeError, 'stop after default startup proof'):
                    runtime_integration.run(root / 'evidence', prepared, ['Run'])
            self.assertEqual(command.call_args.args[3],
                             ['system', 'start', '--app-root', '/private/app', '--debug'])
            result = json.loads((root / 'evidence/integration.json').read_text())
            self.assertEqual(result['selection'], None)

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
            # Relocated Apple binaries retain launch constraints and may be
            # killed asynchronously. Use a fixture that reaches its own main.
            source = '''#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *ready = fopen(argv[1], "w");
    if (!ready) return 3;
    if (fclose(ready)) return 4;
    sleep(60);
    return 0;
}
'''
            subprocess.run(['/usr/bin/cc', '-x', 'c', '-o', str(plugin), '-'],
                           input=source, text=True, capture_output=True, timeout=30, check=True)
            executable.write_text('#!/bin/sh\nexec "' + str(plugin) + '" "$@"\n')
            executable.chmod(0o755)
            records = root / 'records'
            records.mkdir()
            ready = root / 'ready'
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('integration_cli.py')), str(ready)],
                                       start_new_session=True, env=dict(os.environ,
                                           CLITEST_REAL_CLI=str(executable), CLITEST_PROCESS_DIRECTORY=str(records)))
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists(), 'Plugin did not reach main; exit=' + str(process.poll()))
                self.assertIsNone(process.poll())
                actual = subprocess.check_output(['ps', '-p', str(process.pid), '-o', 'comm='],
                                                 text=True, timeout=5).strip()
                self.assertEqual(actual, str(plugin))
                self.assertEqual(set(owned_cli_processes(executable, records)), {process.pid})
                self.assertEqual(stop_test_children(executable, records), [process.pid])
                self.assertEqual(process.wait(timeout=5), -signal.SIGTERM)
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
