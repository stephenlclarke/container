"""A killed wrapper may recover only its own idle, verifiably restored host."""

from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fork_benchmark import digest
import host_lease
import recover_unattended as recovery
import runtime_coverage
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

    def recorded_coverage(self):
        source = self.storage / 'source'
        source.mkdir()
        revision = 'a' * 40
        self.record['bazel_workspace'] = str(source)
        self.save()
        self.stack.enter_context(patch.object(recovery, 'ROOT', source))
        self.stack.enter_context(patch.object(
            recovery, 'checked', side_effect=lambda arguments, **_: revision
            if arguments[-1] == 'HEAD' else ''))
        self.stack.enter_context(patch.object(runtime_coverage, 'stop_owned'))
        idle = self.stack.enter_context(patch.object(recovery, 'require_idle'))
        self.stack.enter_context(patch.object(runtime_coverage, 'require_idle'))
        install = self.installs / 'fork/install'
        install.mkdir(parents=True)
        temporary = install.parent / 'coverage-install-12345678'
        backup = temporary / 'previous'
        backup.mkdir(parents=True)
        marker = {'owner': 'container-runtime-benchmark', 'lane': 'fork', 'schema': 1}
        for directory in (install, backup):
            (directory / '.runtime-benchmark-owner.json').write_text(json.dumps(marker))
            (directory / 'bin').mkdir()
        old = backup / 'bin/container'
        old.write_text('original')
        current = install / 'bin/container'
        current.write_text('instrumented')
        original = {'bin/container': digest(old)}
        instrumented = {'bin/container': digest(current)}
        smoke = self.evidence / 'runtime-smoke'
        smoke.mkdir()
        (smoke / 'fork-fingerprint.json').write_text(json.dumps({'binaries': original}))
        coverage = self.evidence / 'integration/coverage'
        coverage.mkdir(parents=True)
        (coverage / 'fork-fingerprint.json').write_text(json.dumps({'binaries': instrumented}))
        record = {'revision': revision, 'passed': False, 'restored': False,
                  'failures': ['original interrupted qualification'],
                  'original_binaries': original, 'recovery_directory': str(temporary)}
        path = coverage / 'coverage.json'
        path.write_text(json.dumps(record))
        (self.evidence / 'acceptance.json').write_text('{"passed": false}\n')
        return path, install, backup, idle

    def test_recorded_profile_backup_restores_only_failed_run_and_is_idempotent(self):
        path, install, backup, idle = self.recorded_coverage()
        before = path.read_bytes()
        result = recovery.recover(self.evidence)
        self.assertTrue(result['restored'])
        self.assertTrue(result['profiled_installation_recovered'])
        self.assertEqual((install / 'bin/container').read_text(), 'original')
        self.assertFalse(backup.exists())
        self.assertEqual((path.parent / 'coverage-before-recovery.json').read_bytes(), before)
        after = json.loads(path.read_text())
        self.assertTrue(after['restored'])
        self.assertFalse(after['passed'])
        self.assertEqual(after['failures'], ['original interrupted qualification'])
        self.assertNotIn('recovery_directory', after)
        self.assertFalse(json.loads((self.evidence / 'acceptance.json').read_text())['passed'])
        self.assertGreaterEqual(idle.call_count, 2)
        again = recovery.recover(self.evidence)
        self.assertTrue(again['restored'])
        self.assertFalse(again['needed'])
        self.assertEqual((path.parent / 'coverage-before-recovery.json').read_bytes(), before)

    def test_recorded_profile_refuses_active_or_changed_backup_without_deletion(self):
        path, install, backup, idle = self.recorded_coverage()
        original = path.read_bytes()
        idle.side_effect = RuntimeError('private CLI still active')
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('private CLI still active', result['failures'])
        self.assertTrue(backup.exists())
        self.assertEqual((install / 'bin/container').read_text(), 'instrumented')
        self.assertEqual(path.read_bytes(), original)
        idle.side_effect = None
        (backup / 'bin/container').write_text('changed original')
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('Prepared runtime binary changed', ' '.join(result['failures']))
        self.assertTrue(backup.exists())
        self.assertEqual(path.read_bytes(), original)

    def test_recorded_profile_keeps_live_owner_or_busy_lease_untouched(self):
        path, install, backup, _idle = self.recorded_coverage()
        original = path.read_bytes()
        self.processes.return_value = {self.record['owner']: {}}
        self.assert_rejected('still active')
        self.processes.return_value = {}
        descriptor = os.open(self.command_lock, os.O_RDWR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            with patch.object(recovery, 'shutdown_idle_bazel') as shutdown:
                self.assert_rejected('temporarily unavailable')
                shutdown.assert_called_once_with(self.evidence.resolve(), self.record['bazel_workspace'])
        finally:
            os.close(descriptor)
        self.assertEqual(path.read_bytes(), original)
        self.assertTrue(backup.exists())
        self.assertEqual((install / 'bin/container').read_text(), 'instrumented')

    def test_recorded_profile_retries_after_transient_finish_failure_without_rewriting_original(self):
        path, install, backup, _idle = self.recorded_coverage()
        before = path.read_bytes()
        with patch.object(runtime_coverage, 'stop_owned', side_effect=RuntimeError('owned CLI still active')):
            result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertTrue(backup.exists())
        self.assertEqual((install / 'bin/container').read_text(), 'instrumented')
        self.assertEqual((path.parent / 'coverage-before-recovery.json').read_bytes(), before)
        failed = json.loads(path.read_text())
        self.assertEqual(failed['failures'], ['original interrupted qualification', 'owned CLI still active'])
        path.write_text(json.dumps(dict(failed, full_suite=True)))
        tampered = recovery.recover(self.evidence)
        self.assertFalse(tampered['restored'])
        self.assertIn('Previously preserved failed coverage evidence changed', tampered['failures'])
        self.assertTrue(backup.exists())
        path.write_text(json.dumps(failed))
        result = recovery.recover(self.evidence)
        self.assertTrue(result['restored'])
        self.assertEqual((install / 'bin/container').read_text(), 'original')
        self.assertEqual((path.parent / 'coverage-before-recovery.json').read_bytes(), before)
        self.assertEqual(json.loads(path.read_text())['failures'], failed['failures'])
        self.assertFalse(json.loads(path.read_text())['passed'])

    def test_recorded_profile_refuses_redirected_evidence_parents(self):
        path, install, backup, _idle = self.recorded_coverage()
        before = path.read_bytes()
        for parent in (self.evidence / 'integration', self.evidence / 'runtime-smoke'):
            with self.subTest(parent=parent):
                saved = self.storage / parent.name
                parent.rename(saved)
                parent.symlink_to(saved, target_is_directory=True)
                result = recovery.recover(self.evidence)
                self.assertFalse(result['restored'])
                self.assertIn('privately owned', ' '.join(result['failures']))
                self.assertTrue(backup.exists())
                self.assertEqual((install / 'bin/container').read_text(), 'instrumented')
                self.assertEqual(path.read_bytes(), before)
                parent.unlink()
                saved.rename(parent)

    def test_recorded_profile_never_claims_success_if_receipt_write_fails_after_replacement(self):
        path, install, backup, _idle = self.recorded_coverage()
        before = path.read_bytes()
        with patch.object(runtime_coverage.RuntimeCoverage, 'persist',
                          side_effect=OSError('coverage receipt unavailable')):
            result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('coverage receipt unavailable', result['failures'])
        self.assertFalse(backup.exists())
        self.assertEqual((install / 'bin/container').read_text(), 'original')
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual((path.parent / 'coverage-before-recovery.json').read_bytes(), before)
        self.assertTrue(self.journal.exists())
        repeated = recovery.recover(self.evidence)
        self.assertFalse(repeated['restored'])
        self.assertTrue(self.journal.exists())

    def test_recorded_profile_refuses_foreign_path_symlink_and_source_drift(self):
        path, install, backup, _idle = self.recorded_coverage()
        original = path.read_bytes()
        record = json.loads(original)
        record['recovery_directory'] = str(self.storage / 'foreign')
        path.write_text(json.dumps(record))
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('outside the private installation', ' '.join(result['failures']))
        path.write_bytes(original)
        marker = backup / '.runtime-benchmark-owner.json'
        marker.rename(backup / 'real-marker.json')
        marker.symlink_to(backup / 'real-marker.json')
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('symbolic link', ' '.join(result['failures']))
        marker.unlink()
        (backup / 'real-marker.json').rename(marker)
        (install / 'bin/container').write_text('changed instrumented')
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('Prepared runtime binary changed', ' '.join(result['failures']))
        (install / 'bin/container').write_text('instrumented')
        path.write_text(json.dumps(dict(json.loads(original), revision='b' * 40)))
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('source or failed state', ' '.join(result['failures']))
        self.assertTrue(backup.exists())
        self.assertEqual((install / 'bin/container').read_text(), 'instrumented')

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

    def test_idle_bazel_shutdown_allows_recovery_but_live_command_remains_protected(self):
        self.record['bazel_workspace'] = str(self.storage)
        self.save()
        descriptor = os.open(self.command_lock, os.O_RDWR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            with patch.object(recovery, 'shutdown_idle_bazel') as stop:
                self.assert_rejected('temporarily unavailable')
                stop.assert_called_once_with(self.evidence.resolve(), str(self.storage))
            with patch.object(recovery, 'shutdown_idle_bazel',
                              side_effect=lambda *_: fcntl.flock(descriptor, fcntl.LOCK_UN)):
                self.assertTrue(recovery.recover(self.evidence)['restored'])
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
        receipt.write_text('{"restored": true}')
        self.verify.side_effect = RuntimeError('Instrumented installation restoration is unconfirmed')
        result = recovery.recover(self.evidence)
        self.assertFalse(result['restored'])
        self.assertIn('restoration is unconfirmed', ' '.join(result['failures']))

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
