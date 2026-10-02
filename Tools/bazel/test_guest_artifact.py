"""Source changes invalidate guest reuse; packaging keeps required boot paths."""

import json
import hashlib
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import guest_artifact


class GuestArtifactTests(unittest.TestCase):
    def test_rootfs_is_deterministic_and_preserves_preproc_lookup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ['vminitd', 'vmexec']:
                (root / name).write_bytes(name.encode())
            first, second = root / 'first.gz', root / 'second.gz'
            guest_artifact.rootfs(root, first)
            guest_artifact.rootfs(root, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, 'r:gz') as archive:
                self.assertEqual(archive.extractfile('sbin/vmexec').read(), b'vmexec')
                self.assertEqual(archive.getmember('sbin/vminitd').mode, 0o755)
                self.assertEqual(archive.getmember('proc/self/exe').linkname, 'sbin/vminitd')
                self.assertTrue(archive.getmember('proc').isdir())
                self.assertNotIn('sbin/runc', archive.getnames())
            runc = root / 'runc'
            runc.write_bytes(b'optional-runtime')
            guest_artifact.rootfs(root, second, runc)
            with tarfile.open(second, 'r:gz') as archive:
                self.assertEqual(archive.extractfile('sbin/runc').read(), runc.read_bytes())
                self.assertEqual(archive.getmember('sbin/runc').mode, 0o755)
            self.assertNotEqual(first.read_bytes(), second.read_bytes())

    def test_runc_download_and_cache_are_bound_to_source_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            content = b'pinned-runtime'
            sha = hashlib.sha256(content).hexdigest()
            (root / 'Makefile').write_text('RUNC_VERSION := v1.5.1\nRUNC_SHA256_arm64 := ' + sha + '\n')
            def download(arguments, **_kwargs):
                Path(arguments[arguments.index('--output') + 1]).write_bytes(content)
            with mock.patch.object(guest_artifact.subprocess, 'run', side_effect=download) as fetch:
                pin, binary = guest_artifact.runc_asset(root, root / 'cache')
                self.assertEqual(pin['sha256'], sha)
                self.assertEqual(guest_artifact.runc_asset(root, root / 'cache'), (pin, binary))
                fetch.assert_called_once()
                self.assertEqual(fetch.call_args.args[0][-1],
                                 'https://github.com/opencontainers/runc/releases/download/v1.5.1/runc.arm64')
                binary.write_bytes(b'changed')
                with self.assertRaisesRegex(RuntimeError, 'Cached runc checksum'):
                    guest_artifact.runc_asset(root, root / 'cache')
                fetch.assert_called_once()

    def test_runc_missing_pin_and_corrupt_download_cannot_be_staged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Makefile').write_text('RUNC_VERSION := v1.5.1\n')
            with mock.patch.object(guest_artifact.subprocess, 'run') as fetch:
                with self.assertRaisesRegex(RuntimeError, 'unambiguous'):
                    guest_artifact.runc_asset(root, root / 'cache')
                fetch.assert_not_called()
            (root / 'Makefile').write_text('RUNC_VERSION := v1.5.1\nRUNC_SHA256_arm64 := ' + 'a' * 64 + '\n')
            def download(arguments, **_kwargs):
                Path(arguments[arguments.index('--output') + 1]).write_bytes(b'incorrect')
            with mock.patch.object(guest_artifact.subprocess, 'run', side_effect=download):
                with self.assertRaisesRegex(RuntimeError, 'Downloaded runc checksum'):
                    guest_artifact.runc_asset(root, root / 'cache')
            self.assertEqual(list((root / 'cache').iterdir()), [])

    def test_source_reuse_detects_mutation_and_keeps_unchanged_timestamps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tmp').mkdir()
            source, repo = root / 'source', root / 'repo'
            repo.mkdir()
            def git(*args):
                return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.email', 'fixture@example.invalid')
            git('config', 'user.name', 'Fixture')
            git('config', 'commit.gpgsign', 'false')
            (repo / 'source.swift').write_text('source')
            git('add', '.')
            git('commit', '-qm', 'test: first fixture')
            revision = git('rev-parse', 'HEAD')
            with mock.patch.object(guest_artifact, 'STORAGE', root):
                original = guest_artifact.snapshot(repo, revision, source)
                timestamp = (source / 'source.swift').stat().st_mtime_ns
                self.assertEqual(guest_artifact.snapshot(repo, revision, source), original)
                (repo / 'README.md').write_text('documentation')
                git('add', '.')
                git('commit', '-qm', 'docs: fixture')
                newer = git('rev-parse', 'HEAD')
                guest_artifact.snapshot(repo, newer, source)
                self.assertEqual((source / 'source.swift').stat().st_mtime_ns, timestamp)
                (source / 'source.swift').write_text('modified')
                with self.assertRaisesRegex(RuntimeError, 'snapshot changed'):
                    guest_artifact.snapshot(repo, newer, source)

    def test_unowned_source_directory_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / 'mine').write_text('keep')
            with self.assertRaisesRegex(RuntimeError, 'unowned'):
                guest_artifact.snapshot(source, 'a' * 40, source)
            self.assertEqual((source / 'mine').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
