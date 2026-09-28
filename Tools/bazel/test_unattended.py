"""Admission and cleanup never stop a pre-existing or newly occupied Docker VM."""

from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from unattended import ColimaLease
import unattended
import linux_tests


class OwnershipTests(unittest.TestCase):
    def test_idle_server_shutdown_releases_lease_but_surviving_controller_does_not(self):
        for release in (True, False):
            with self.subTest(release=release), tempfile.TemporaryDirectory() as directory, ExitStack() as commands:
                root = Path(directory).resolve()
                descriptor = os.open(root / 'commands.lock', os.O_CREAT | os.O_RDWR, 0o600)
                fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
                def shutdown(*_args):
                    if release:
                        fcntl.flock(descriptor, fcntl.LOCK_UN)
                try:
                    with patch.object(unattended, 'shutdown_idle_bazel', side_effect=shutdown) as stop:
                        if release:
                            self.assertEqual(len(unattended.acquire_cleanup_commands(root, commands, str(root))), 1)
                        else:
                            with self.assertRaises(BlockingIOError):
                                unattended.acquire_cleanup_commands(root, commands, str(root))
                        stop.assert_called_once_with(root, str(root))
                finally:
                    os.close(descriptor)

    def test_shutdown_is_bounded_nonblocking_and_requires_recorded_workspace(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(unattended.subprocess, 'run') as run:
            root = Path(directory).resolve()
            for workspace in ('relative', str(root / 'missing')):
                with self.assertRaisesRegex(RuntimeError, 'workspace is unavailable'):
                    unattended.shutdown_idle_bazel(root, workspace)
            run.assert_not_called()
            unattended.shutdown_idle_bazel(root, str(root))
            self.assertEqual(run.call_args.args[0][-2:], ['--noblock_for_lock', 'shutdown'])
            self.assertEqual(run.call_args.kwargs['timeout'], 30)
            self.assertTrue(run.call_args.kwargs['check'])
            run.side_effect = subprocess.CalledProcessError(9, 'busy Bazel server')
            with self.assertRaises(subprocess.CalledProcessError):
                unattended.shutdown_idle_bazel(root, str(root))

    def test_explicit_failed_api_hold_is_admitted_only_after_other_checks_pass(self):
        for other_failure in (False, True):
            with self.subTest(other_failure=other_failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text('{"failed_api_hold":{"approved":"identity"}}')
                checks = [{'check': 'apple-runtime-slot', 'ready': False},
                          {'check': 'signing', 'ready': not other_failure}]
                events = []
                with patch.object(unattended, 'STORAGE', root), \
                        patch.object(unattended, 'CONFIG', config), \
                        patch.object(unattended, 'check', return_value={'ready': False, 'checks': checks}), \
                        patch.object(unattended, 'HostLease') as host, \
                        patch.object(unattended, 'StockSlot') as slot, \
                        patch.object(unattended, 'ColimaLease'), \
                        patch.object(unattended, 'Runner') as runner, \
                        patch.object(unattended, 'verify_installations'), \
                        patch.object(unattended, 'hold_failed_api', side_effect=lambda *args: events.append('api-hold')) as hold, \
                        patch.object(unattended, 'apple_runtime_slot_ready', return_value=True), \
                        patch.object(unattended.signal, 'signal'), \
                        patch('sys.argv', ['unattended', '--evidence', str(root / 'evidence')]):
                    host.return_value.acquire.side_effect = lambda: events.append('host-lock')
                    slot.return_value.acquire.side_effect = lambda: events.append('slot')
                    runner.return_value.run.return_value = {'status': 0}
                    if other_failure:
                        with self.assertRaises(SystemExit):
                            unattended.main()
                        host.assert_not_called()
                        hold.assert_not_called()
                    else:
                        unattended.main()
                        self.assertEqual(events, ['host-lock', 'api-hold', 'slot'])
                        before = json.loads((root / 'evidence/preflight-before-api-hold.json').read_text())
                        after = json.loads((root / 'evidence/preflight.json').read_text())
                        self.assertFalse(before['ready'])
                        self.assertTrue(after['ready'])
                        self.assertTrue(after['checks'][0]['explicit_failed_api_hold'])

    def test_original_services_are_held_until_qualification_and_cleanup_finish(self):
        for failure in (None, 'build', 'colima-cleanup', 'stock-cleanup', 'install-cleanup'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                events = []
                with patch.object(unattended, 'STORAGE', root), \
                        patch.object(unattended, 'CONFIG', root / 'config.json'), \
                        patch.object(unattended, 'check', return_value={'ready': True}), \
                        patch.object(unattended, 'HostLease') as host, \
                        patch.object(unattended, 'StockSlot') as slot, \
                        patch.object(unattended, 'ColimaLease') as lease, \
                        patch.object(unattended, 'Runner') as runner, \
                        patch.object(unattended, 'verify_installations') as restored, \
                        patch.object(unattended.signal, 'signal'), \
                        patch('sys.argv', ['unattended', '--evidence', str(root / 'evidence')]):
                    host.return_value.acquire.side_effect = lambda: events.append('host-lock')
                    host.return_value.restore.side_effect = lambda **kwargs: events.append('workers-restore' if kwargs['restore_workers'] else 'workers-quarantined')
                    host.return_value.close.side_effect = lambda: events.append('host-unlock')
                    slot.return_value.acquire.side_effect = lambda: events.append('hold')
                    lease.return_value.acquire.side_effect = lambda: events.append('colima')
                    runner.return_value.run.side_effect = lambda *args, **kwargs: events.append('build') or {'status': 1 if failure == 'build' else 0, 'log': 'build.log'}

                    def restore_install(_evidence):
                        events.append('install-check')
                        if failure == 'install-cleanup':
                            raise RuntimeError('installation restoration unconfirmed')

                    restored.side_effect = restore_install

                    def cleanup():
                        events.append('colima-cleanup')
                        if failure == 'colima-cleanup':
                            raise RuntimeError('cleanup failed')

                    lease.return_value.restore.side_effect = cleanup
                    def restore_stock():
                        events.append('restore')
                        if failure == 'stock-cleanup':
                            raise RuntimeError('stock restoration failed')

                    slot.return_value.restore.side_effect = restore_stock
                    if failure:
                        with self.assertRaises((RuntimeError, SystemExit)):
                            unattended.main()
                    else:
                        unattended.main()
                self.assertEqual(events, ['host-lock', 'hold', 'colima', 'build', 'install-check', 'colima-cleanup', 'restore',
                                         'workers-quarantined' if failure in ('colima-cleanup', 'stock-cleanup', 'install-cleanup') else 'workers-restore', 'host-unlock'])
                result = json.loads((root / 'evidence/acceptance.json').read_text())
                self.assertEqual(result['passed'], failure is None)

    def test_surviving_controller_also_blocks_normal_wrapper_cleanup(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as commands:
            root = Path(directory)
            lock = root / 'commands.lock'
            lock.touch(mode=0o600)
            environment = {unattended.COMMAND_LOCK_ENV: str(lock)}
            commands.enter_context(unattended.command_lease(environment))
            host, lease, slot = Mock(), Mock(), Mock()
            result = {'passed': True, 'failures': []}
            with unattended.command_lease(environment), patch.object(unattended, 'verify_installations') as verify:
                unattended.restore_host(root, host, lease, slot, commands, result)
            self.assertFalse(result['passed'])
            verify.assert_not_called()
            lease.restore.assert_not_called()
            slot.restore.assert_not_called()
            host.restore.assert_called_once_with(restore_workers=False)
            host.close.assert_called_once()

    def test_unrestored_instrumented_binaries_quarantine_normal_cleanup(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as commands, \
                patch.object(unattended, 'require_idle'):
            root = Path(directory)
            (root / 'commands.lock').touch(mode=0o600)
            coverage = root / 'integration/coverage'
            coverage.mkdir(parents=True)
            (coverage / 'coverage.json').write_text('{"restored": false}')
            host, lease, slot = Mock(), Mock(), Mock()
            result = {'passed': True, 'failures': []}
            unattended.restore_host(root, host, lease, slot, commands, result)
            self.assertFalse(result['passed'])
            self.assertIn('Instrumented installation', ' '.join(result['failures']))
            lease.restore.assert_called_once()
            slot.restore.assert_called_once()
            host.restore.assert_called_once_with(restore_workers=False)

    def test_preexisting_vm_is_not_stopped(self):
        with tempfile.TemporaryDirectory() as directory, patch('unattended.subprocess.run') as run:
            lease = ColimaLease(Path(directory))
            lease.restore()
            run.assert_not_called()
            self.assertTrue(lease.record['restored'])

    def test_new_workloads_prevent_owned_vm_shutdown(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch('unattended.output', side_effect=[json.dumps({'name': 'default', 'status': 'Running'}), 'unrelated']), \
                patch('unattended.subprocess.run') as run:
            lease = ColimaLease(Path(directory))
            lease.record['started_by_this_run'] = True
            with self.assertRaisesRegex(RuntimeError, 'remain active'):
                lease.restore()
            run.assert_not_called()
            self.assertFalse(lease.record['restored'])

    def test_idle_owned_vm_is_restored(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch('unattended.output', side_effect=[json.dumps({'name': 'default', 'status': 'Running'}), '']), \
                patch('unattended.subprocess.run') as run:
            lease = ColimaLease(Path(directory))
            lease.record['started_by_this_run'] = True
            lease.command_descriptors = (55,)
            lease.restore()
            self.assertEqual(run.call_args.args[0], ['colima', 'stop'])
            self.assertEqual(run.call_args.kwargs['pass_fds'], (55,))
            self.assertTrue(lease.record['restored'])

    def test_linux_cleanup_rejects_unrelated_container(self):
        record = {'Config': {'Labels': {'io.container-only.owner': 'somebody-else'}}, 'Id': 'other'}
        import subprocess
        with patch('linux_tests.subprocess.run', return_value=subprocess.CompletedProcess([], 0, json.dumps([record]))) as run:
            with self.assertRaisesRegex(RuntimeError, 'ownership label'):
                linux_tests.cleanup('colima', 'owned')
            self.assertEqual(run.call_count, 1)

    def test_linux_daemon_loss_is_not_successful_cleanup(self):
        import subprocess
        with patch('linux_tests.subprocess.run', side_effect=[
                subprocess.CompletedProcess([], 1), subprocess.CalledProcessError(1, 'docker info')]):
            with self.assertRaises(subprocess.CalledProcessError):
                linux_tests.cleanup('colima', 'owned')


if __name__ == '__main__':
    unittest.main()
