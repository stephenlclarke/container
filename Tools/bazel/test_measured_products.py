"""Release retention preserves exact measured executables before distribution signing."""

import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import release_artifact as release
from fork_benchmark import digest


class MeasuredProductsTests(unittest.TestCase):
    def fixture(self, root, lane='fork'):
        prepared = root / 'prepared'
        prepared.mkdir()
        install = root / 'install'
        paths = {'bin/container', 'bin/container-apiserver'} | {
            f'libexec/container/plugins/{name}/bin/{name}' for name in release.PLUGINS}
        if lane == 'fork':
            paths |= {'bin/container-engine', 'libexec/container/helpers/container-semantic-helper',
                      'libexec/container/helpers/container-semantic-helper.manifest.json'}
        hashes = {}
        for name in paths:
            path = install / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('signed measured bytes: ' + name).encode())
            path.chmod(0o644 if name.endswith('.json') else 0o755)
            hashes[name] = digest(path)
        (install / '.runtime-benchmark-owner.json').write_text('private owner state')
        (prepared / (lane + '-fingerprint.json')).write_text(json.dumps(
            dict(lane=lane, install=str(install), binaries=hashes, kernel_sha256='b' * 64, workload_image='image@sha256:' + 'c' * 64)))
        (prepared / 'source-inputs.json').write_text(json.dumps({lane: 'a' * 40}))
        return prepared, install, hashes

    def test_exact_fork_and_stock_bytes_modes_only_and_no_overwrite(self):
        for lane, count in [('fork', 10), ('stock', 7)]:
            with self.subTest(lane=lane), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepared, install, hashes = self.fixture(root, lane)
                result = release.retain_measured_products(prepared, root, lane=lane)
                self.assertEqual(len(result['payload']), count)
                self.assertFalse(result['resigned'])
                self.assertEqual(result['runtime_identity']['kernel_sha256'], 'b' * 64)
                self.assertEqual(result['archive_sha256'], digest(root / result['archive']))
                with tarfile.open(root / result['archive']) as archive:
                    self.assertEqual(set(archive.getnames()), set(hashes))
                    for item in archive.getmembers():
                        self.assertEqual(archive.extractfile(item).read(), (install / item.name).read_bytes())
                        self.assertEqual(item.mode, (install / item.name).stat().st_mode & 0o777)
                self.assertEqual(hashes, {name: digest(install / name) for name in hashes})
                with self.assertRaisesRegex(RuntimeError, 'already exists'):
                    release.retain_measured_products(prepared, root, lane=lane)

    def test_drift_unexpected_path_and_symlink_fail_without_completed_manifest(self):
        for mutation in ('bytes', 'extra', 'symlink', 'directory-symlink', 'special-mode'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepared, install, _ = self.fixture(root)
                binary = install / 'bin/container'
                if mutation == 'bytes': binary.write_bytes(b'not measured')
                if mutation == 'symlink':
                    target = root / 'elsewhere'
                    shutil.copy2(binary, target)
                    binary.unlink()
                    binary.symlink_to(target)
                if mutation == 'directory-symlink':
                    (install / 'bin').rename(root / 'outside-bin')
                    (install / 'bin').symlink_to(root / 'outside-bin')
                if mutation == 'special-mode': binary.chmod(0o4755)
                if mutation == 'extra':
                    path = prepared / 'fork-fingerprint.json'
                    record = json.loads(path.read_text())
                    record['binaries']['../outside'] = 'b' * 64
                    path.write_text(json.dumps(record))
                with self.assertRaises(RuntimeError):
                    release.retain_measured_products(prepared, root)
                self.assertFalse((root / 'container-measured-fork-arm64.json').exists())

    def test_benchmark_linkage_requires_same_fingerprint_and_passing_receipt(self):
        for changed in (None, 'fingerprint', 'failed'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepared, _, _ = self.fixture(root)
                benchmark = root / 'runtime-benchmark'
                benchmark.mkdir()
                for name in ('fork-fingerprint.json', 'source-inputs.json'):
                    shutil.copy2(prepared / name, benchmark / name)
                for name in ('results.json', 'matrix.json', 'host.json'):
                    (benchmark / name).write_text('{}')
                (benchmark / 'acceptance.json').write_text(json.dumps({'passed': changed != 'failed'}))
                if changed == 'fingerprint':
                    path = benchmark / 'fork-fingerprint.json'
                    record = json.loads(path.read_text())
                    record['binaries']['bin/container'] = 'b' * 64
                    path.write_text(json.dumps(record))
                if changed:
                    with self.assertRaisesRegex(RuntimeError, 'provenance'):
                        release.retain_measured_products(prepared, root, benchmark=benchmark)
                    self.assertFalse((root / 'container-measured-fork-arm64.tar.gz').exists())
                else:
                    result = release.retain_measured_products(prepared, root, benchmark=benchmark)
                    self.assertEqual(len(result['benchmark_provenance_sha256']), 6)
                    for name, expected in result['benchmark_provenance_sha256'].items():
                        self.assertEqual(digest(benchmark / name), expected)

    def test_capture_finishes_before_original_package_resigning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepared, _, hashes = self.fixture(root)
            for name in ('guest-artifact.json', 'builder-artifact.json'):
                (prepared / name).write_text('{}')
            evidence = root / 'release-output'
            def command(_runner, name, arguments, _timeout):
                self.assertEqual(name, 'package')
                manifest = json.loads((evidence / 'container-measured-fork-arm64.json').read_text())
                self.assertEqual({name: row['sha256'] for name, row in manifest['payload'].items()}, hashes)
                self.assertIn('--timestamp', ' '.join(arguments))
                raise RuntimeError('stop before distribution signing')
            with patch.object(release, 'STORAGE', root), patch.object(release, 'verify_prepared'), \
                    patch.object(release, 'service_directories', return_value={'journald': root, 'gelf': root}), \
                    patch.object(release, 'run_command', side_effect=command):
                with self.assertRaisesRegex(RuntimeError, 'stop before distribution signing'):
                    release.build(evidence, prepared, root / 'unused-services', None)
            result = json.loads((evidence / 'release-artifact.json').read_text())
            self.assertFalse(result['passed'])
            self.assertEqual(result['measured_products']['source'], 'a' * 40)


if __name__ == '__main__':
    unittest.main()
