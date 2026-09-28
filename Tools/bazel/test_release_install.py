"""An extracted package must match the signed and retained payload exactly."""

import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from fork_benchmark import digest
from release_install import checked_payload
import release_install


class InstallationTransactionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.installs = self.root / 'installs'
        self.installation = self.installs / 'fork/install'
        self.installation.mkdir(parents=True)
        self.original = self.installation / 'container'
        self.original.write_bytes(b'original executable')
        (self.installation / '.runtime-benchmark-owner.json').write_text('{}')
        self.original_binaries = {'container': digest(self.original)}
        self.release = self.root / 'release'
        self.release.mkdir()
        self.evidence = self.root / 'evidence'
        self.state = self.root / 'state'
        logs = self.state / 'fork/logs'
        logs.mkdir(parents=True)
        (logs / 'server.log').write_text('retained server output')
        source = self.release / 'candidate'
        source.write_bytes(b'candidate executable')
        archive = self.release / 'container-homebrew-arm64.tar.gz'
        with tarfile.open(archive, 'w:gz') as package:
            package.add(source, arcname='container')
        qualification = dict(passed=True, archives={archive.name: digest(archive)},
                             payload={'container': digest(source)}, notarized=True, source='revision')
        (self.release / 'release-artifact.json').write_text(json.dumps(qualification))
        metadata = dict(binaries=self.original_binaries, init_image='guest', builder_image='builder', kernel_sha256='kernel')
        (self.release / 'fork-fingerprint.json').write_text(json.dumps(metadata))
        for name in ('source-inputs.json', 'guest-artifact.json', 'builder-artifact.json'):
            (self.release / name).write_text('{}')
        for name, value in (('INSTALLS', self.installs), ('STATE', self.state)):
            self.enterContext(patch.object(release_install, name, value))
        for name in ('verify_prepared', 'stop_owned', 'require_idle', 'own'):
            setattr(self, name, self.enterContext(patch.object(release_install, name)))
        self.enterContext(patch.object(release_install, 'reset_state', return_value='kernel'))
        runner = self.enterContext(patch.object(release_install, 'RuntimeRunner'))
        runner.return_value.rows = []
        self.workload = self.enterContext(patch.object(release_install, 'run_lane'))

    def receipt(self):
        return json.loads((self.evidence / 'install.json').read_text())

    def assert_restored(self):
        self.assertEqual(self.original.read_bytes(), b'original executable')
        self.assertTrue(self.receipt()['previous_installation_restored'])
        self.assertNotIn('recovery_directory', self.receipt())
        self.assertEqual(list(self.installation.parent.glob('release-install-*')), [])
        release_install.require_restored(self.evidence)

    def test_success_persists_recovery_before_moving_original(self):
        rename = Path.rename

        def observed_rename(source, target):
            if source == self.installation:
                receipt = self.receipt()
                self.assertTrue(receipt['replacement_started'])
                self.assertFalse(receipt['previous_installation_restored'])
                self.assertEqual(receipt['original_binaries'], self.original_binaries)
                self.assertEqual(Path(receipt['recovery_directory']) / 'previous', target)
            return rename(source, target)

        with patch.object(Path, 'rename', observed_rename):
            release_install.run(self.evidence, self.release)
        self.assertTrue(self.receipt()['passed'])
        self.assert_restored()

    def test_log_retention_failure_still_restores_original(self):
        with patch.object(release_install.shutil, 'copytree', side_effect=OSError('log copy failed')):
            with self.assertRaisesRegex(OSError, 'log copy failed'):
                release_install.run(self.evidence, self.release)
        self.assertFalse(self.receipt()['passed'])
        self.assert_restored()

    def test_workload_failure_and_interruption_restore_original(self):
        for failure in (RuntimeError('workload failed'), SystemExit(143)):
            with self.subTest(failure=failure):
                self.evidence = self.root / type(failure).__name__
                self.workload.side_effect = failure
                with self.assertRaises(type(failure)):
                    release_install.run(self.evidence, self.release)
                self.assertFalse(self.receipt()['passed'])
                self.assert_restored()

    def test_surviving_process_preserves_candidate_and_original_backup(self):
        self.require_idle.side_effect = [None, RuntimeError('active processes')]
        with self.assertRaisesRegex(RuntimeError, 'active processes'):
            release_install.run(self.evidence, self.release)
        receipt = self.receipt()
        self.assertFalse(receipt['passed'])
        self.assertFalse(receipt['previous_installation_restored'])
        self.assertEqual(self.original.read_bytes(), b'candidate executable')
        self.assertEqual((Path(receipt['recovery_directory']) / 'previous/container').read_bytes(), b'original executable')
        with self.assertRaisesRegex(RuntimeError, 'restoration is unconfirmed'):
            release_install.require_restored(self.evidence)

    def test_failed_backup_restore_retains_recovery_directory(self):
        rename = Path.rename

        def failed_restore(source, target):
            if source.name == 'previous':
                raise OSError('backup restore failed')
            return rename(source, target)

        with patch.object(Path, 'rename', failed_restore):
            with self.assertRaisesRegex(OSError, 'backup restore failed'):
                release_install.run(self.evidence, self.release)
        receipt = self.receipt()
        self.assertFalse(receipt['previous_installation_restored'])
        self.assertEqual((Path(receipt['recovery_directory']) / 'previous/container').read_bytes(), b'original executable')
        with self.assertRaisesRegex(RuntimeError, 'restoration is unconfirmed'):
            release_install.require_restored(self.evidence)

    def test_failed_initial_move_confirms_unchanged_original(self):
        with patch.object(Path, 'rename', side_effect=OSError('initial move failed')):
            with self.assertRaisesRegex(OSError, 'initial move failed'):
                release_install.run(self.evidence, self.release)
        self.assert_restored()

    def test_restored_binary_mismatch_cannot_be_accepted(self):
        def corrupt_backup(*_args):
            receipt = self.receipt()
            (Path(receipt['recovery_directory']) / 'previous/container').write_bytes(b'corrupted original')

        self.workload.side_effect = corrupt_backup
        with self.assertRaisesRegex(RuntimeError, 'binary changed'):
            release_install.run(self.evidence, self.release)
        self.assertFalse(self.receipt()['previous_installation_restored'])
        self.assertIn('recovery_directory', self.receipt())

    def test_restoration_admission_rejects_missing_corrupt_or_incomplete_receipt(self):
        release_install.require_restored(self.evidence)  # No install stage entered.
        self.evidence.mkdir()
        with self.assertRaises(FileNotFoundError):
            release_install.require_restored(self.evidence)
        for text in ('{', '{}', '{"replacement_started": true}',
                     '{"replacement_started": true, "previous_installation_restored": true}'):
            with self.subTest(text=text):
                (self.evidence / 'install.json').write_text(text)
                with self.assertRaises((ValueError, RuntimeError)):
                    release_install.require_restored(self.evidence)

    def test_restoration_admission_rechecks_actual_binaries(self):
        release_install.run(self.evidence, self.release)
        self.original.write_bytes(b'changed after restoration')
        with self.assertRaisesRegex(RuntimeError, 'binary changed'):
            release_install.require_restored(self.evidence)


class ReleaseInstallTests(unittest.TestCase):
    def test_changed_and_additional_package_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'container'
            source.write_bytes(b'original executable')
            expected = {'bin/container': digest(source)}
            archive = root / 'archive.tar'
            with tarfile.open(archive, 'w') as package:
                package.add(source, arcname='bin/container')
            checked_payload(archive, root / 'valid', expected)
            with tarfile.open(archive, 'a') as package:
                extra = tarfile.TarInfo('bin/unexpected')
                extra.size = 3
                package.addfile(extra, io.BytesIO(b'bad'))
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                checked_payload(archive, root / 'extra', expected)


if __name__ == '__main__':
    unittest.main()
