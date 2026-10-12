"""Published lower layers must retain source, asset and executable identity."""

import hashlib
import gzip
import io
import json
from pathlib import Path
import tarfile
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

import published_lower as lower


GUEST = 'a' * 40
BUILDER = 'b' * 40


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class PublishedLowerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.locks = self.root / 'locks'
        self.locks.mkdir()
        self.archive = self.root / 'guest.oci.tar'
        self.archive.write_bytes(b'fixture-archive')
        self.sidecar = self.root / 'qualified-guest-artifacts.json'
        self.qualification = {name: {'source': GUEST, 'passed': True,
                                     'evidenceSHA256': sha(name.encode())}
                              for name in ('native', 'linux', 'sonar', 'focusedVM')}
        self.qualification['focusedVM']['guestArchiveSHA256'] = sha(b'runc-archive')
        self.sidecar_data = {'schema': 1, 'kind': 'qualified-guest-artifacts',
                             'repository': lower.GUEST_REPO, 'tag': 'guest-release',
                             'source': GUEST, 'qualification': {'passed': True, **self.qualification},
                             'artifacts': {
                                 'guest': {'archive_sha256': sha(b'fixture-archive'),
                                           'producerReceiptSHA256': sha(b'producer'),
                                           'reference': 'ghcr.io/stephenlclarke/containerization/vminit:' + GUEST,
                                           'identity': {'source': GUEST},
                                           'binaries': {'vminitd': sha(b'init'), 'vmexec': sha(b'exec')}},
                                 'guest-runc': {'archive_sha256': sha(b'runc-archive'),
                                                'producerReceiptSHA256': sha(b'runc-producer'),
                                                'reference': 'ghcr.io/stephenlclarke/containerization/vminit-runc:' + GUEST,
                                                'identity': {'source': GUEST, 'runc': {'sha256': sha(b'runc')}},
                                                'binaries': {'vminitd': sha(b'init'), 'vmexec': sha(b'exec'),
                                                             'runc': sha(b'runc')}}}}
        self.write_locks()

    def write_locks(self):
        self.sidecar.write_text(json.dumps(self.sidecar_data))
        for name, asset, digest in (('guest', self.archive.name, sha(self.archive.read_bytes())),
                                    ('guest-evidence', self.sidecar.name, sha(self.sidecar.read_bytes()))):
            (self.locks / (name + '.lock.json')).write_text(json.dumps({
                'schema': 1, 'repository': lower.GUEST_REPO, 'tag': 'guest-release',
                'targetCommit': GUEST, 'asset': asset, 'sha256': digest}))

    def fetched(self, lock, _cache):
        item = json.loads(Path(lock).read_text())
        return {'asset': str(self.root / item['asset']), 'sha256': item['sha256'],
                'releaseId': 12, 'assetId': 2 if item['asset'] == self.sidecar.name else 1}

    def test_guest_import_emits_unchanged_receipt_without_build(self):
        with patch.object(lower, 'source_for', return_value=GUEST), \
                patch.object(lower, 'cached_fetch', side_effect=self.fetched), \
                patch.object(lower, 'validate_oci', return_value={'layer': 'sha256:' + '0' * 64}), \
                patch.object(lower, 'guest_binaries', return_value=(self.sidecar_data['artifacts']['guest']['binaries'], None)):
            record = lower.import_layer('guest', self.root / 'out', locks=self.locks, cache=self.root / 'cache')
        self.assertEqual(record['identity']['source'], GUEST)
        self.assertEqual(record['archive'], str(self.archive))
        self.assertEqual(json.loads((self.root / 'out/guest-artifact.json').read_text()), record)
        self.assertEqual(json.loads((self.root / 'out/published-import.json').read_text())['archiveAssetId'], 1)

    def test_guest_rejects_bad_source_hash_ids_and_sidecar(self):
        for change in ('source', 'sha', 'ids', 'sidecar', 'vm'):
            with self.subTest(change=change):
                self.write_locks()
                original = self.fetched
                def fetched(lock, cache):
                    row = original(lock, cache)
                    if change == 'ids': row['assetId'] = 1
                    return row
                if change == 'source':
                    item = json.loads((self.locks / 'guest.lock.json').read_text())
                    item['targetCommit'] = 'c' * 40
                    (self.locks / 'guest.lock.json').write_text(json.dumps(item))
                elif change == 'sha':
                    item = json.loads((self.locks / 'guest.lock.json').read_text())
                    item['sha256'] = sha(b'incorrect')
                    (self.locks / 'guest.lock.json').write_text(json.dumps(item))
                elif change == 'sidecar':
                    self.sidecar_data['qualification']['linux']['passed'] = False
                    self.write_locks()
                elif change == 'vm':
                    self.sidecar_data['qualification']['focusedVM']['guestArchiveSHA256'] = sha(b'wrong')
                    self.write_locks()
                with patch.object(lower, 'source_for', return_value=GUEST), \
                        patch.object(lower, 'cached_fetch', side_effect=fetched):
                    with self.assertRaises(RuntimeError):
                        lower.admitted_pair('guest', self.locks, self.root / 'cache')
                self.sidecar_data['qualification']['linux']['passed'] = True
                self.sidecar_data['qualification']['focusedVM']['guestArchiveSHA256'] = sha(b'runc-archive')

    def test_runc_does_not_accept_different_executable(self):
        self.sidecar_data['artifacts']['guest-runc']['binaries']['runc'] = sha(b'other')
        self.write_locks()
        runc = self.root / 'guest-runc.oci.tar'
        runc.write_bytes(b'runc-archive')
        (self.locks / 'guest-runc.lock.json').write_text(json.dumps({
            'schema': 1, 'repository': lower.GUEST_REPO, 'tag': 'guest-release',
            'targetCommit': GUEST, 'asset': runc.name, 'sha256': sha(runc.read_bytes())}))
        with patch.object(lower, 'source_for', return_value=GUEST), \
                patch.object(lower, 'cached_fetch', side_effect=self.fetched), \
                patch.object(lower, 'validate_oci', return_value={'layer': 'sha256:' + '0' * 64}), \
                patch.object(lower, 'guest_binaries', return_value=(
                    {'vminitd': sha(b'init'), 'vmexec': sha(b'exec'), 'runc': sha(b'runc')}, b'runc')):
            with self.assertRaisesRegex(RuntimeError, 'guest executables'):
                lower.import_layer('guest-runc', self.root / 'out', locks=self.locks, cache=self.root / 'cache')
        self.assertFalse((self.root / 'out').exists())

    def test_builder_test_archive_requires_each_original_hash(self):
        files = {name: name.encode() for name in ('tests.json', 'toolchain.txt', 'coverage.out', 'coverage-summary.txt')}
        tests_archive = self.root / 'builder-qualification.tar.gz'
        with tarfile.open(tests_archive, 'w:gz') as output:
            for name, data in files.items():
                item = tarfile.TarInfo(name)
                item.size = len(data)
                output.addfile(item, io.BytesIO(data))
        builder_doc = {'tag': 'builder-release', 'qualification': {
            'containerSource': lower.Q6FE, 'producerReceiptSHA256': sha(b'builder-receipt'),
            'acceptanceSHA256': sha(b'acceptance'), 'testsArchiveSHA256': sha(tests_archive.read_bytes())}}
        artifact = {'archive_sha256': sha(b'builder'), 'producerReceiptSHA256': sha(b'builder-receipt'),
                    'qualification_files': {name: sha(data) for name, data in files.items()}}
        provenance = {'qualified_container_source': lower.Q6FE,
                      'qualification': {'target': 'bazel-qualify', 'passed': True},
                      'source_receipt_sha256': {'runtime-smoke/builder-artifact.json': sha(b'builder-receipt'),
                                                'acceptance.json': sha(b'acceptance')},
                      'assets': {'builder': {'sha256': sha(b'builder')}}}
        public = self.root / 'qualified-container-assets.json'
        public.write_text(json.dumps(provenance))
        for name, repo, tag, target, asset, digest in (
                ('builder-anchor', 'stephenlclarke/container', 'q-release', lower.Q6FE,
                 public.name, sha(public.read_bytes())),
                ('builder-tests', lower.BUILDER_REPO, 'builder-release', BUILDER,
                 tests_archive.name, sha(tests_archive.read_bytes()))):
            (self.locks / (name + '.lock.json')).write_text(json.dumps({
                'schema': 1, 'repository': repo, 'tag': tag, 'targetCommit': target,
                'asset': asset, 'sha256': digest}))
        def fetched(lock, _cache):
            item = json.loads(Path(lock).read_text())
            return {'asset': str(self.root / item['asset']), 'releaseId': 7, 'assetId': 3}
        with patch.object(lower, 'source_pin', return_value=BUILDER), \
                patch.object(lower, 'cached_fetch', side_effect=fetched):
            result, _ = lower.builder_qualification(builder_doc, artifact, self.locks,
                                                    self.root / 'cache', 7, {1, 2})
            self.assertEqual(result, files)
            artifact['qualification_files']['tests.json'] = sha(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'output differs'):
                lower.builder_qualification(builder_doc, artifact, self.locks,
                                            self.root / 'cache', 7, {1, 2})

    def test_real_guest_archive_requires_exact_reference_and_executable_bytes(self):
        reference = 'ghcr.io/stephenlclarke/containerization/vminit:' + GUEST
        rootfs = self.root / 'rootfs.tar.gz'
        contents = {'sbin/vminitd': b'init-program', 'sbin/vmexec': b'exec-program'}
        with rootfs.open('wb') as output, gzip.GzipFile(fileobj=output, mode='wb', mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w|') as root:
                for name, data in contents.items():
                    item = tarfile.TarInfo(name)
                    item.mode, item.size = 0o755, len(data)
                    root.addfile(item, io.BytesIO(data))
        archive = self.root / 'valid.oci.tar'
        subprocess.run([sys.executable, str(Path(lower.__file__).with_name('create-vminit-oci-archive.py')),
                        '--rootfs', str(rootfs), '--output', str(archive), '--reference', reference,
                        '--source-url', 'https://github.com/stephenlclarke/containerization'], check=True,
                       capture_output=True, text=True)
        observed = lower.validate_oci(archive, reference)
        binaries, runc = lower.guest_binaries(archive, observed['layer'])
        self.assertEqual(binaries, {'vminitd': sha(b'init-program'), 'vmexec': sha(b'exec-program')})
        self.assertIsNone(runc)
        with self.assertRaisesRegex(Exception, 'required reference'):
            lower.validate_oci(archive, reference[:-1] + 'b')
        broken = self.root / 'broken.oci.tar'
        broken.write_bytes(archive.read_bytes()[:archive.stat().st_size // 2])
        with self.assertRaises(Exception):
            lower.validate_oci(broken, reference)


if __name__ == '__main__':
    unittest.main()
