"""A killed wrapper may recover only its own idle, verifiably restored host."""

from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import host_lease
import recover_unattended as recovery
import unattended


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        root = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.evidence = root / 'evidence'
        self.evidence.mkdir()
        self.storage = root / 'storage'
        self.storage.mkdir()
        self.installs = root / 'installs'
        self.installs.mkdir()
        self.journal = root / 'journal.json'
        self.shared_lock = root / 'shared.lock'
        for module, name, value in ((recovery, 'STORAGE', self.storage),
                                    (recovery, 'INSTALLS', self.installs),
                                    (recovery, 'LOCK', self.shared_lock),
                                    (recovery, 'JOURNAL', self.journal),
                                    (host_lease, 'JOURNAL', self.journal)):
            self.stack.enter_context(patch.object(module, name, value))
        self.stack.enter_context(patch.dict(os.environ, GITHUB_ACTIONS='true', GITHUB_RUN_ID='12'))
        self.processes = self.stack.enter_context(patch.object(recovery, 'processes', return_value={}))
        self.stop = self.stack.enter_context(patch.object(recovery, 'stop_owned'))
        self.verify = self.stack.enter_context(patch.object(recovery, 'verify_installations'))
        self.command_lock = self.evidence / 'commands.lock'
        self.command_lock.touch(mode=0o600)
        self.record = dict(owner=987654, evidence=str(self.evidence), github_run_id='12',
                           command_lock=str(self.command_lock), workers=[], suspended=[], acquired=True,
                           restored=False)
        self.save()

    def save(self):
        self.journal.write_text(json.dumps(self.record))

    def assert_rejected(self, reason):
        original = self.journal.read_bytes()
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn(reason, ' '.join(result['failures']))
        self.assertEqual(self.journal.read_bytes(), original)
        self.stop.assert_not_called()

    def test_restores_own_dead_run_then_repeated_recovery_is_noop(self):
        (self.evidence / 'colima-lease.json').write_text(json.dumps({'started_by_this_run': False}))
        (self.evidence / 'service-restoration.json').write_text('[]')
        result = recovery.recover(self.evidence)
        self.assertTrue(result['restored'])
        self.assertTrue(result['needed'])
        self.assertFalse(self.journal.exists())
        self.assertTrue(json.loads((self.evidence / 'host-lease.json').read_text())['restored'])
        self.assertFalse((self.evidence / 'acceptance.json').exists())
        inodes = {p: p.stat().st_ino for p in (self.shared_lock, self.command_lock,
                  self.storage / 'qualification.lock', self.installs / 'benchmark.lock')}
        repeated = recovery.recover(self.evidence)
        self.assertTrue(repeated['restored'])
        self.assertFalse(repeated['needed'])
        self.assertEqual(inodes, {p: p.stat().st_ino for p in inodes})

    def test_live_owner_is_never_recovered(self):
        self.processes.return_value = {self.record['owner']: {}}
        self.assert_rejected('still active')

    def test_other_evidence_and_run_id_cannot_be_recovered(self):
        for key, value, reason in (('evidence', '/another/run', 'another invocation'),
                                    ('github_run_id', '13', 'different GitHub run')):
            with self.subTest(key=key):
                old = self.record[key]
                self.record[key] = value
                self.save()
                self.assert_rejected(reason)
                self.record[key] = old

    def test_busy_host_or_orphaned_command_keeps_recovery_read_only(self):
        for path, mode in ((self.shared_lock, fcntl.LOCK_EX), (self.command_lock, fcntl.LOCK_SH)):
            with self.subTest(path=path):
                descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
                try:
                    fcntl.flock(descriptor, mode | fcntl.LOCK_NB)
                    self.assert_rejected('temporarily unavailable')
                finally:
                    os.close(descriptor)

    def test_unsafe_lock_and_legacy_or_missing_command_lease_fail_closed(self):
        self.command_lock.unlink()
        target = self.evidence / 'unrelated'
        target.write_text('preserve')
        self.command_lock.symlink_to(target)
        self.assert_rejected('symbolic links')
        self.assertEqual(target.read_text(), 'preserve')
        self.command_lock.unlink()
        self.assert_rejected('No such file')
        del self.record['command_lock']
        self.save()
        self.assert_rejected('manual verification')

    def test_missing_journal_requires_affirmative_previous_restoration(self):
        self.journal.unlink()
        receipt = self.evidence / 'host-lease.json'
        for text in ('{"restored": false}', '{'):
            receipt.write_text(text)
            self.assertFalse(recovery.recover(self.evidence)['restored'])
        self.stop.assert_not_called()

    def test_changed_command_path_and_writable_lock_fail_closed(self):
        self.record['command_lock'] = '/another/commands.lock'
        self.save()
        self.assert_rejected('does not match')
        self.record['command_lock'] = str(self.command_lock)
        self.save()
        self.command_lock.chmod(0o666)
        self.assert_rejected('private single-owner')
        self.command_lock.chmod(0o600)
        self.shared_lock.chmod(0o666)
        self.assert_rejected('private single-owner')

    def test_symbolic_journal_does_not_convey_authority(self):
        target = self.evidence / 'original-journal.json'
        self.journal.rename(target)
        self.journal.symlink_to(target)
        self.assert_rejected('symbolic link')

    def test_binary_uncertainty_keeps_workers_quiesced_and_journal_retained(self):
        self.verify.side_effect = RuntimeError('Original binary still replaced')
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('Original binary still replaced', result['failures'])
        self.assertIn('workers remain quiesced', ' '.join(result['failures']))
        self.assertFalse(json.loads(self.journal.read_text())['restored'])

    def test_one_resource_failure_still_attempts_other_restoration(self):
        (self.evidence / 'colima-lease.json').write_text('{}')
        (self.evidence / 'service-restoration.json').write_text('[]')
        with patch.object(recovery.ColimaLease, 'restore', side_effect=RuntimeError('Colima uncertain')), \
                patch.object(recovery.StockSlot, 'restore') as stock:
            result = recovery.recover(self.evidence)
        stock.assert_called_once()
        self.assertFalse(result['restored'])
        self.assertTrue(self.journal.exists())

    def test_report_failure_releases_all_locks(self):
        write = Path.write_text

        def fail_report(path, *args, **kwargs):
            if path.name.startswith('recovery-'):
                raise OSError('report volume full')
            return write(path, *args, **kwargs)

        with patch.object(Path, 'write_text', fail_report):
            result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('report volume full', ' '.join(result['failures']))
        for path in (self.shared_lock, self.command_lock, self.storage / 'qualification.lock',
                     self.installs / 'benchmark.lock'):
            with path.open() as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


class InstallationEvidenceTests(unittest.TestCase):
    def test_incomplete_or_corrupt_coverage_restoration_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(unattended, 'require_idle'), \
                patch.object(unattended, 'require_restored'), patch.object(unattended, 'verify_binaries') as verify:
            evidence = Path(temporary)
            recovery.verify_installations(evidence)
            coverage = evidence / 'integration/coverage'
            coverage.mkdir(parents=True)
            with self.assertRaises(FileNotFoundError):
                recovery.verify_installations(evidence)
            for record in ({}, {'restored': True}, {'restored': False, 'original_binaries': {'bin/container': 'old'}}):
                (coverage / 'coverage.json').write_text(json.dumps(record))
                with self.assertRaisesRegex(RuntimeError, 'unconfirmed'):
                    recovery.verify_installations(evidence)
            expected = {'bin/container': 'original'}
            (coverage / 'coverage.json').write_text(json.dumps({'restored': True, 'original_binaries': expected}))
            recovery.verify_installations(evidence)
            verify.assert_called_once_with(recovery.INSTALLS / 'fork/install', expected)


if __name__ == '__main__':
    unittest.main()
