"""Admission and cleanup never stop a pre-existing or newly occupied Docker VM."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from unattended import ColimaLease
import unattended
import linux_tests


class OwnershipTests(unittest.TestCase):
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
                        patch.object(unattended, 'require_restored') as restored, \
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
            lease.restore()
            self.assertEqual(run.call_args.args[0], ['colima', 'stop'])
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
