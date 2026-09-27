"""Admission and cleanup never stop a pre-existing or newly occupied Docker VM."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from unattended import ColimaLease
import linux_tests


class OwnershipTests(unittest.TestCase):
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
