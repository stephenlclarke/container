"""Permission failures are bounded and never turn into a successful admission."""

import os
import subprocess
import unittest
from unittest import mock

import preflight


class PreflightTests(unittest.TestCase):
    def test_timeout_and_missing_program_are_blocked(self):
        for error in [FileNotFoundError(), subprocess.TimeoutExpired(['probe'], 1)]:
            with self.subTest(error=type(error).__name__), mock.patch.object(preflight.subprocess, 'run', side_effect=error):
                self.assertEqual(preflight.command(['probe']), (124, ''))

    def test_command_cannot_wait_for_terminal_input(self):
        with mock.patch.object(preflight.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'ready', '')) as run:
            self.assertEqual(preflight.command(['probe']), (0, 'ready'))
            self.assertEqual(run.call_args.kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(run.call_args.kwargs['timeout'], 20)

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
