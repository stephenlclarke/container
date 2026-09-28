"""Permission failures are bounded and never turn into a successful admission."""

import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import preflight


class PreflightTests(unittest.TestCase):
    def test_runtime_admission_requires_current_inactive_state(self):
        label = 'com.apple.container.apiserver'
        for state, pid, status, ready in [
                ('not running', '-', 0, True), ('spawn scheduled', '-', 0, False),
                ('running', '123', 0, False), ('waiting', '-', 0, False),
                ('', '-', 0, False), ('not running', '-', 124, False)]:
            with self.subTest(state=state, pid=pid, status=status), \
                    mock.patch.object(preflight, 'command', side_effect=[
                        (0, f'{pid}\t1\t{label}'), (status, f'{label} = {{\n\tstate = {state}\n}}')]) as command:
                self.assertEqual(preflight.apple_runtime_slot_ready(), ready)
                self.assertTrue(all(call.args[0][1] in ('list', 'print') for call in command.call_args_list))
        with mock.patch.object(preflight, 'command', return_value=(124, '')):
            self.assertFalse(preflight.apple_runtime_slot_ready())
        with mock.patch.object(preflight, 'command', return_value=(0, 'PID Status Label\n1 0 unrelated')):
            self.assertTrue(preflight.apple_runtime_slot_ready())

    def test_available_swift_does_not_admit_command_line_tools_as_xcode(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'bazel'
            binary.write_bytes(b'fixture')
            def probe(arguments, **_kwargs):
                return (1, '') if arguments[0] == '/usr/bin/xcodebuild' else (0, '')
            with mock.patch.object(preflight, 'BAZEL', binary), \
                    mock.patch.object(preflight, 'command', side_effect=probe):
                report = preflight.check('build', {})
            checks = {row['check']: row for row in report['checks']}
            self.assertTrue(checks['swift-toolchain']['ready'])
            self.assertFalse(checks['xcode-toolchain']['ready'])
            self.assertIn('full Xcode', checks['xcode-toolchain']['action'])
            self.assertFalse(report['ready'])

    def test_dns_probe_requires_both_native_families_within_proxy_deadline(self):
        rows = [{'type': kind, 'outcome': 'resolved', 'seconds': .1} for kind in ('A', 'AAAA')]
        with mock.patch.object(preflight, 'command', return_value=(0, json.dumps(rows))) as probe:
            self.assertTrue(preflight.host_dns_probe()['ready'])
            self.assertEqual(probe.call_args.kwargs['timeout'], 4)
        for outcome, seconds in [('resolved', 3), ('resolved', 3.9), ('resolver-error', .1), ('empty', .1)]:
            rows[1].update(outcome=outcome, seconds=seconds)
            with self.subTest(outcome=outcome, seconds=seconds), mock.patch.object(preflight, 'command', return_value=(0, json.dumps(rows))):
                self.assertFalse(preflight.host_dns_probe()['ready'])

    def test_dns_probe_timeout_and_malformed_output_fail_without_retry(self):
        for status, raw in [(124, ''), (1, ''), (0, '{}'), (0, '[]'), (0, 'invalid'),
                            (0, '[{}, {}]'), (0, '[null, null]')]:
            with self.subTest(status=status, raw=raw), mock.patch.object(preflight, 'command', return_value=(status, raw)) as probe:
                self.assertFalse(preflight.host_dns_probe()['ready'])
                probe.assert_called_once()

    def test_timeout_and_missing_program_are_blocked(self):
        for error in [FileNotFoundError(), subprocess.TimeoutExpired(['probe'], 1)]:
            with self.subTest(error=type(error).__name__), mock.patch.object(preflight.subprocess, 'run', side_effect=error):
                self.assertEqual(preflight.command(['probe']), (124, ''))

    def test_command_cannot_wait_for_terminal_input(self):
        with mock.patch.object(preflight.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'ready', '')) as run:
            self.assertEqual(preflight.command(['probe']), (0, 'ready'))
            self.assertEqual(run.call_args.kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(run.call_args.kwargs['timeout'], 20)

    def test_extractor_probe_writes_only_to_disposable_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            storage = Path(directory)
            extractor = storage / 'toolchains/codeql-2.27.1/codeql/swift/tools/osx64/extractor'
            extractor.parent.mkdir(parents=True)
            extractor.write_text('#!/bin/sh\nmkdir -p extractor-out\npwd > extractor-out/invocation\npwd\n')
            extractor.chmod(0o700)
            with mock.patch.object(preflight, 'STORAGE', storage), mock.patch.object(preflight, 'command', wraps=preflight.command) as probe:
                self.assertTrue(preflight.swift_extractor_ready())
                working_directory = probe.call_args.kwargs['cwd']
                self.assertNotEqual(working_directory, Path.cwd())
                self.assertFalse(working_directory.exists())

    def test_refreshed_keyring_is_not_shadowed_by_inherited_tokens(self):
        with mock.patch.dict(os.environ, {'GITHUB_TOKEN': 'secret', 'GH_TOKEN': 'secret', 'KEEP': 'yes'}, clear=True):
            self.assertEqual(preflight.github_environment(), {'KEEP': 'yes'})

    def test_package_scope_requires_explicit_authority(self):
        self.assertEqual(preflight.token_scopes('HTTP/2 200\r\nX-OAuth-Scopes: repo, workflow\r\n\r\n{}'), {'repo', 'workflow'})
        self.assertNotIn('write:packages', preflight.token_scopes('{"write:packages":true}'))
        self.assertIn('write:packages', preflight.token_scopes('x-oauth-scopes: repo, write:packages\n'))

    def test_missing_sonar_token_does_not_make_request(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(preflight.urllib.request, 'urlopen') as request:
            self.assertFalse(preflight.sonar_authenticated())
            request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
