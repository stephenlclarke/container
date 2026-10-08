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
    def test_fresh_state_preserves_unmarked_previous_scratch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / 'fork/integration'
            old.mkdir(parents=True)
            (old / 'preserve').write_text('previous run data')
            with mock.patch.object(runtime_integration, 'STATE', root):
                first = runtime_integration.fresh_integration_state()
                second = runtime_integration.fresh_integration_state()
            self.assertNotEqual(first, second)
            self.assertEqual(first.parent, old.parent)
            self.assertLessEqual(len(first.name), len(old.name))
            for state in (first, second):
                marker = json.loads((state / '.runtime-benchmark-owner.json').read_text())
                self.assertEqual(marker['lane'], 'integration')
            self.assertEqual((old / 'preserve').read_text(), 'previous run data')
            self.assertFalse((old / '.runtime-benchmark-owner.json').exists())

    def test_fresh_state_rejects_collision_instead_of_claiming_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            occupied = root / 'fork/it-12345678'
            occupied.mkdir(parents=True)
            (occupied / 'preserve').write_text('unrelated data')
            with (mock.patch.object(runtime_integration, 'STATE', root),
                  mock.patch.object(runtime_integration.uuid, 'uuid4',
                                    return_value=mock.Mock(hex='12345678' + '0' * 24))):
                with self.assertRaisesRegex(RuntimeError, 'already exists'):
                    runtime_integration.fresh_integration_state()
            self.assertEqual((occupied / 'preserve').read_text(), 'unrelated data')

    def test_prepared_native_receipt_binds_unsigned_products_without_live_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Sources').mkdir()
            (root / 'Sources/a.swift').write_text('struct A {}\n')
            (root / 'Package.resolved').write_text('{}\n')
            prepared = root / 'prepared'
            prepared.mkdir()
            (prepared / 'compiled-consumer.json').write_text('{"passed":true}\n')
            names = ('container', 'container-apiserver', 'container-engine',
                     'container-runtime-linux', 'container-network-vmnet',
                     'container-core-images', 'machine-apiserver', 'k8s')
            records = {'bazel-out/opt/bin/external/+dependencies+swiftpkg_container/' +
                       name + '.rspm.__impl': {'sha256': str(index) * 64}
                       for index, name in enumerate(names, 1)}
            compiled = {'build': {'files': records}}
            unsigned = runtime_integration.native_consumer.unsigned_product_hashes(compiled)
            fingerprint = {'package_lock_sha256': runtime_integration.digest(root / 'Package.resolved'),
                           'compiled_consumer_sha256': runtime_integration.digest(
                               prepared / 'compiled-consumer.json'),
                           'unsigned_native_inputs': unsigned}
            (prepared / 'fork-fingerprint.json').write_text(json.dumps(fingerprint))
            (prepared / 'source-inputs.json').write_text(json.dumps({
                'fork': 'a' * 40, 'source_sha256': {'fork': {
                    'Sources/a.swift': runtime_integration.digest(root / 'Sources/a.swift')}},
                'build_inputs': {}}))
            with (mock.patch.object(runtime_integration, 'ROOT', root),
                  mock.patch.object(runtime_integration, 'build_inputs', return_value={}),
                  mock.patch.object(runtime_integration.native_layers, 'import_layers',
                                    return_value={'layers': {}}),
                  mock.patch.object(runtime_integration.native_consumer, 'verify_receipt',
                                    return_value=compiled) as verify):
                runtime_integration.verify_prepared(prepared)
                self.assertNotIn('output_base', verify.call_args.kwargs)
                fingerprint['unsigned_native_inputs']['container'] = 'f' * 64
                (prepared / 'fork-fingerprint.json').write_text(json.dumps(fingerprint))
                with self.assertRaisesRegex(RuntimeError, 'native compiler inputs'):
                    runtime_integration.verify_prepared(prepared)

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
            for name in ('source-inputs.json', 'guest-artifact.json', 'builder-artifact.json',
                         'compiled-consumer.json', 'fork-release.events.json',
                         'fork-release-native-aquery.json'):
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
