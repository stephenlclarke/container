#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Import real sealed fixture bytes without contacting Bazel or a release host."""

import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock

from Tools.bazel.artifacts import native_format, native_layers, native_producer, recipe_compatibility


class NativeLayerTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='q-native-import-', dir=Path.home())
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.q = self.root / 'q'
        self.q.mkdir()
        policy = self.q / 'Tools/bazel/artifacts/recipe_compatibility.py'
        policy.parent.mkdir(parents=True)
        shutil.copyfile(Path(recipe_compatibility.__file__), policy)
        self.locks = self.root / 'locks'
        self.locks.mkdir()
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        self.source = 'a' * 40
        self.toolchain = {'bazelVersion': '8.8.0', 'swiftcSHA256': 'b' * 64}
        self.recipe = {'Package.swift': 'c' * 64, **recipe_compatibility.NEW}
        self.pins = {
            name: {'identity': name, 'kind': 'remoteSourceControl',
                   'location': 'https://github.com/example/' + name,
                   'state': {'revision': character * 40}}
            for name, character in (
                ('swift-argument-parser', '1'), ('swift-log', '2'),
                ('containerization', '3'), ('container-engine-api', '4'),
                ('container', '5'))
        }
        (self.q / 'Package.resolved').write_text(json.dumps({'pins': list(self.pins.values())}))
        self.pairs = {}
        self.receipts = {}
        for group in native_layers.ALL_GROUPS:
            self.make_group(group)
        self.enterContext(mock.patch.object(native_layers, 'toolchain', return_value=self.toolchain))
        self.enterContext(mock.patch.object(native_layers, 'recipe', return_value=self.recipe))
        self.enterContext(mock.patch.object(native_layers.platform, 'system', return_value='Darwin'))
        self.enterContext(mock.patch.object(native_layers.platform, 'machine', return_value='arm64'))
        self.real_release_pair = native_layers._release_pair
        self.proof_verify = self.enterContext(mock.patch.object(
            native_producer, 'verify_proof_bundle', return_value={'passed': True}))
        self.fetch = self.enterContext(mock.patch.object(
            native_layers, '_release_pair', side_effect=lambda name, locks, cache: self.pairs[name]))
        self.run = self.enterContext(mock.patch.object(
            native_layers.subprocess, 'check_output', return_value=self.source + '\n'))

    def make_group(self, group):
        selected = native_layers.group_pins(group, self.pins)
        required = {'argument-parser': 'swift-argument-parser',
                    'foundation': 'swift-log', 'containerization': 'containerization',
                    'engine-api': 'container-engine-api'}[group]
        repository = native_layers.repo_name(required)
        build = b'filegroup(name = "prebuilt", srcs = ["binary/libProduct.a"])\n'
        members = {
            f'{group}/{repository}/BUILD.bazel': build,
            f'{group}/{repository}/binary/libProduct.a': b'compiled ' + group.encode(),
        }
        binary_member = f'{group}/{repository}/binary/libProduct.a'
        configured = f'bazel-out/darwin_arm64-opt/bin/external/+dependencies+{repository}/libProduct.a'
        lower = {name: native_layers.lower_identity(self.receipts[name])
                 for name in native_layers.LOWER[group]}
        producer = (self.pins[required]['state']['revision']
                    if group in ('containerization', 'engine-api') else self.source)
        manifest = {
            'schema': 1, 'group': group, 'graph': 'container-native',
            'profile': 'native', 'configuration': 'opt', 'platform': 'darwin-arm64',
            'developmentProof': False, 'producerCommit': producer,
            'sourcePins': selected, 'recipeSHA256': self.recipe,
            'toolchain': self.toolchain, 'lower': lower,
            'packages': {required: {
                'sourceCommit': self.pins[required]['state']['revision'],
                'sourceLocation': self.pins[required]['location'],
                'repository': repository, 'generatedBuildSHA256': native_format.digest(build)}},
            'payloadOutputs': {binary_member: configured},
            'files': {name: native_format.digest(content) for name, content in members.items()},
        }
        archive = self.root / f'{group}.tar.gz'
        archive.write_bytes(native_format.archive_bytes(members, manifest))
        archive_sha = native_layers.digest(archive)
        proof_dir = self.root / group
        proof_dir.mkdir(exist_ok=True)
        proof_bundle = proof_dir / f'{group}-native-proof.tar.gz'
        proof_member = f'{group}/producer/build.log'
        proof_bytes = b'published command and test evidence for ' + group.encode()
        proof_manifest = {'schema': 1, 'group': group, 'profile': 'native',
                          'kind': 'q-native-public-proof',
                          'files': {proof_member: native_format.digest(proof_bytes)}}
        proof_bundle.write_bytes(native_format.archive_bytes({proof_member: proof_bytes}, proof_manifest))
        proof_sha = native_layers.digest(proof_bundle)
        qualification_sha = native_format.digest(('qualified ' + group).encode())
        sidecar = {
            'schema': 1, 'group': group, 'archiveSHA256': archive_sha,
            'source': producer, 'sourcePins': selected, 'recipeSHA256': self.recipe,
            'toolchain': self.toolchain, 'lower': lower,
            'manifestSHA256': hashlib.sha256(
                (json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest(),
            'producerBuild': {'files': {configured: {'sha256': manifest['files'][binary_member]}}},
            'qualificationSHA256': qualification_sha,
            'qualification': {'passed': True, 'group': group, 'source': producer,
                              'qualificationSHA256': qualification_sha},
            'proofBundle': {'schema': 1, 'asset': proof_bundle.name, 'sha256': proof_sha},
            'passed': True, 'developmentProof': False,
        }
        evidence = self.root / f'{group}.json'
        evidence.write_text(json.dumps(sidecar))
        evidence_sha = native_layers.digest(evidence)
        release = 'release-' + group
        product = {'asset': str(archive), 'assetId': 100 + len(self.pairs), 'releaseId': release}
        proof = {'asset': str(evidence), 'assetId': 200 + len(self.pairs), 'releaseId': release}
        portable = {'asset': str(proof_bundle), 'assetId': 300 + len(self.pairs),
                    'releaseId': release}
        pair = {
            'archive': {'repository': native_layers.GROUP_OWNER[group],
                        'asset': f'{group}-native-darwin-arm64-opt.tar.gz',
                        'targetCommit': producer, 'sha256': archive_sha},
            'evidence': {'repository': native_layers.GROUP_OWNER[group],
                         'asset': f'{group}-native-evidence.json',
                         'targetCommit': producer, 'sha256': evidence_sha},
            'proof': {'repository': native_layers.GROUP_OWNER[group],
                      'asset': f'{group}-native-proof.tar.gz',
                      'targetCommit': producer, 'sha256': proof_sha},
            'lockSHA256': {'archive': '6' * 64, 'evidence': '7' * 64, 'proof': '8' * 64},
        }
        self.pairs[group] = product, proof, portable, pair
        self.receipts[group] = {
            'archiveSHA256': archive_sha, 'evidenceSHA256': evidence_sha,
            'proofSHA256': proof_sha,
            'assetId': product['assetId'], 'evidenceAssetId': proof['assetId'],
            'proofAssetId': portable['assetId'],
            'lockSHA256': pair['lockSHA256'], 'releaseId': release,
            'producerCommit': producer, 'sourcePins': selected,
        }

    def imported(self, groups=native_layers.GROUPS):
        return native_layers.import_layers(self.q, self.locks, self.cache, groups=groups)

    def reseal_manifest(self, group, update):
        product, proof, portable, pair = self.pairs[group]
        archive = Path(product['asset'])
        manifest = native_format.inspect(archive)['manifest']
        with tarfile.open(archive, 'r:gz') as source:
            members = {item.name: source.extractfile(item).read() for item in source
                       if item.name != group + '/layer.json'}
        update(manifest)
        archive.write_bytes(native_format.archive_bytes(members, manifest))
        pair['archive']['sha256'] = native_layers.digest(archive)
        sidecar_path = Path(proof['asset'])
        sidecar = json.loads(sidecar_path.read_text())
        sidecar['archiveSHA256'] = pair['archive']['sha256']
        sidecar['sourcePins'] = manifest['sourcePins']
        sidecar['manifestSHA256'] = hashlib.sha256(
            (json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest()
        sidecar_path.write_text(json.dumps(sidecar))
        pair['evidence']['sha256'] = native_layers.digest(sidecar_path)

    def test_exact_chain_extracts_only_selected_packages_and_builds_canonical_flags(self):
        admitted = self.imported()
        self.assertEqual(list(admitted['layers']), list(native_layers.ALL_GROUPS))
        self.assertTrue(all(layer['recipeCompatibility']['mode'] == 'exact'
                            for layer in admitted['layers'].values()))
        self.assertEqual(admitted['layers']['engine-api']['lower']['foundation'],
                         native_layers.lower_identity(admitted['layers']['foundation']))
        self.assertIn('+dependencies+swiftpkg_swift_argument_parser', admitted['overrides'])
        self.assertIn('+dependencies+swiftpkg_containerization', admitted['overrides'])
        for canonical, selected in admitted['overrides'].items():
            self.assertEqual((Path(selected) / 'BUILD.bazel').read_bytes(),
                             b'filegroup(name = "prebuilt", srcs = ["binary/libProduct.a"])\n')
            self.assertTrue(Path(selected).is_relative_to(self.cache))
            self.assertTrue(canonical.startswith('+dependencies+swiftpkg_'))
        self.assertEqual(len(native_layers.bazel_flags(admitted)), len(admitted['overrides']))
        self.assertEqual(self.run.call_count, 1)
        self.assertEqual(self.proof_verify.call_count, len(native_layers.ALL_GROUPS))

    def test_lower_archive_identity_and_selected_source_cannot_be_relabelled(self):
        product, proof, portable, pair = self.pairs['foundation']
        sidecar = Path(proof['asset'])
        changed = json.loads(sidecar.read_text())
        changed['lower']['argument-parser']['archiveSHA256'] = '0' * 64
        sidecar.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, 'matching passed evidence'):
            self.imported(groups=('foundation',))

        self.make_group('foundation')
        product, proof, portable, pair = self.pairs['foundation']
        pair['archive']['targetCommit'] = 'f' * 40
        with self.assertRaisesRegex(ValueError, 'selected Q source graph'):
            self.imported(groups=('foundation',))

    def test_changed_manifest_source_and_sidecar_source_fail_closed(self):
        product, proof, portable, pair = self.pairs['argument-parser']
        evidence = Path(proof['asset'])
        sidecar = json.loads(evidence.read_text())
        sidecar['source'] = 'f' * 40
        evidence.write_text(json.dumps(sidecar))
        with self.assertRaisesRegex(ValueError, 'matching passed evidence'):
            self.imported(groups=())

        self.make_group('argument-parser')
        self.reseal_manifest('argument-parser', lambda manifest: manifest['sourcePins'][
            'swift-argument-parser']['state'].update(revision='f' * 40))
        with self.assertRaisesRegex(ValueError, 'selected Q source graph'):
            self.imported(groups=())

    def test_binary_and_source_test_proofs_cannot_be_omitted_or_relabelled(self):
        for change in ('binary-hash', 'test-source', 'test-hash'):
            self.make_group('argument-parser')
            proof = Path(self.pairs['argument-parser'][1]['asset'])
            sidecar = json.loads(proof.read_text())
            if change == 'binary-hash':
                configured = next(iter(sidecar['producerBuild']['files']))
                sidecar['producerBuild']['files'][configured]['sha256'] = '0' * 64
            elif change == 'test-source':
                sidecar['qualification']['source'] = 'f' * 40
            else:
                sidecar['qualificationSHA256'] = '0' * 64
            proof.write_text(json.dumps(sidecar))
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'incomplete'):
                self.imported(groups=())

        self.make_group('argument-parser')
        self.reseal_manifest('argument-parser', lambda manifest: manifest.update(payloadOutputs={}))
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            self.imported(groups=())

    def test_proof_asset_binding_and_replay_failure_are_not_optional(self):
        for changed in ({'asset': 'another-proof.tar.gz'}, {'sha256': '0' * 64}):
            self.make_group('argument-parser')
            sidecar_path = Path(self.pairs['argument-parser'][1]['asset'])
            sidecar = json.loads(sidecar_path.read_text())
            sidecar['proofBundle'].update(changed)
            sidecar_path.write_text(json.dumps(sidecar))
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, 'proof asset'):
                self.imported(groups=())
        self.proof_verify.assert_not_called()

        self.make_group('argument-parser')
        self.proof_verify.side_effect = ValueError('portable proof replay failed')
        with self.assertRaisesRegex(ValueError, 'portable proof replay failed'):
            self.imported(groups=())
        self.proof_verify.assert_called_once()

    def test_cached_extra_file_changed_bytes_or_mode_are_rejected(self):
        admitted = self.imported(groups=())
        package = Path(admitted['overrides']['+dependencies+swiftpkg_swift_argument_parser'])
        extra = package / 'unexpected.swift'
        extra.write_text('print("not sealed")\n')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            self.imported(groups=())
        extra.unlink()

        binary = package / 'binary/libProduct.a'
        binary.write_bytes(b'changed binary')
        with self.assertRaisesRegex(ValueError, 'differs from published archive'):
            self.imported(groups=())
        binary.write_bytes(b'compiled argument-parser')

        binary.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'differs from published archive'):
            self.imported(groups=())

    def test_symlink_cache_parent_is_rejected_before_asset_lookup(self):
        real = self.root / 'real-cache'
        real.mkdir()
        alias = self.root / 'alias-cache'
        alias.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            native_layers.import_layers(self.q, self.locks, alias, groups=())
        self.fetch.assert_not_called()

        real_group = self.root / 'real-group'
        real_group.mkdir()
        (self.cache / 'argument-parser').symlink_to(real_group, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.imported(groups=())
        self.fetch.assert_not_called()

    def test_loaded_build_must_resolve_to_exact_extracted_repository(self):
        admitted = self.imported(groups=())
        canonical, selected = next(iter(admitted['overrides'].items()))
        output = self.root / 'output'
        external = output / 'external'
        external.mkdir(parents=True)
        loaded = external / canonical
        loaded.symlink_to(selected, target_is_directory=True)
        self.assertEqual(native_layers.verify_loaded_repositories(admitted, output)[canonical],
                         native_layers.digest(Path(selected) / 'BUILD.bazel'))
        loaded.unlink()
        fallback = self.root / 'source-fallback'
        fallback.mkdir()
        (fallback / 'BUILD.bazel').write_bytes((Path(selected) / 'BUILD.bazel').read_bytes())
        loaded.symlink_to(fallback, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'ignored or redirected'):
            native_layers.verify_loaded_repositories(admitted, output)

    def test_asset_triple_requires_same_release_distinct_ids_and_proof_hash(self):
        archive = self.root / 'asset.tar.gz'
        archive.write_bytes(b'published archive')
        evidence = self.root / 'evidence.json'
        evidence.write_text('{}')
        proof = self.root / 'proof.tar.gz'
        proof.write_bytes(b'published portable proof')
        lock_rows = [
            {'repository': 'stephenlclarke/container', 'tag': 'native-v1',
             'targetCommit': self.source, 'asset': 'foundation-native-darwin-arm64-opt.tar.gz',
             'sha256': native_layers.digest(archive)},
            {'repository': 'stephenlclarke/container', 'tag': 'native-v1',
             'targetCommit': self.source, 'asset': 'foundation-native-evidence.json',
             'sha256': native_layers.digest(evidence)},
            {'repository': 'stephenlclarke/container', 'tag': 'native-v1',
             'targetCommit': self.source, 'asset': 'foundation-native-proof.tar.gz',
             'sha256': native_layers.digest(proof)},
        ]
        for suffix, row in zip(('archive', 'evidence', 'proof'), lock_rows):
            (self.locks / f'foundation.{suffix}.lock.json').write_text(json.dumps(row))
        products = [
            {'asset': str(archive), 'assetId': 1, 'releaseId': 99},
            {'asset': str(evidence), 'assetId': 2, 'releaseId': 99},
            {'asset': str(proof), 'assetId': 3, 'releaseId': 99},
        ]
        with mock.patch.object(native_layers, 'read_lock', side_effect=lock_rows), \
                mock.patch.object(native_layers, 'cached_fetch', side_effect=products):
            self.assertEqual(self.real_release_pair('foundation', self.locks, self.cache)
                             [0]['releaseId'], 99)
        for changed in ({'releaseId': 100}, {'assetId': 1}):
            wrong = dict(products[2], **changed)
            with self.subTest(changed=changed), \
                    mock.patch.object(native_layers, 'read_lock', side_effect=lock_rows), \
                    mock.patch.object(native_layers, 'cached_fetch', side_effect=[*products[:2], wrong]), \
                    self.assertRaisesRegex(ValueError, 'asset triple changed'):
                self.real_release_pair('foundation', self.locks, self.cache)
        proof.write_bytes(b'changed portable proof')
        with mock.patch.object(native_layers, 'read_lock', side_effect=lock_rows), \
                mock.patch.object(native_layers, 'cached_fetch', side_effect=products), \
                self.assertRaisesRegex(ValueError, 'asset triple changed'):
            self.real_release_pair('foundation', self.locks, self.cache)
        wrong_lock = dict(lock_rows[2], tag='another-release')
        with mock.patch.object(native_layers, 'read_lock', side_effect=[*lock_rows[:2], wrong_lock]), \
                mock.patch.object(native_layers, 'cached_fetch') as fetch, \
                self.assertRaisesRegex(ValueError, 'not one release'):
            self.real_release_pair('foundation', self.locks, self.cache)
        fetch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
