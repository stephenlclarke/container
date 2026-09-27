"""Source changes invalidate guest reuse; packaging keeps required boot paths."""

import json
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
