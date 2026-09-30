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

"""Finite tests for native compiled-consumer action and archive admission."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from Tools.bazel.artifacts import native_consumer


class NativeConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.names = sorted(native_consumer.REQUIRED_LINK_REPOSITORIES)
        self.name = self.names[0]
        self.repositories = {name: self.root / name.removeprefix('+dependencies+')
                             for name in self.names}
        for repository in self.repositories.values():
            (repository / 'binary').mkdir(parents=True)
            (repository / 'binary/libLower.a').write_bytes(b'compiled lower archive')
        self.admission = {'source': 'a' * 40,
                          'overrides': {name: str(path) for name, path in self.repositories.items()},
                          'layers': {}}
        self.loaded = {name: 'b' * 64 for name in self.names}
        fragments = [{'id': 1, 'label': 'external'}]
        for index, name in enumerate(self.names):
            base = 2 + index * 3
            fragments += [{'id': base, 'label': name, 'parentId': 1},
                          {'id': base + 1, 'label': 'binary', 'parentId': base},
                          {'id': base + 2, 'label': 'libLower.a', 'parentId': base + 1}]
        self.graph = {
            'targets': [{'id': i, 'label': label} for i, label in enumerate(
                sorted(native_consumer.LINKS), 1)],
            'pathFragments': fragments,
            'artifacts': [{'id': index + 1, 'pathFragmentId': 4 + index * 3}
                          for index in range(len(self.names))],
            'depSetOfFiles': [{'id': 1, 'directArtifactIds': list(range(1, len(self.names) + 1))}],
            'actions': [{'targetId': i, 'mnemonic': 'CppLink', 'inputDepSetIds': [1]}
                        for i in range(1, 9)],
        }

    def verify(self):
        path = self.root / 'aquery.json'
        path.write_text('Evidence: retained\n' + json.dumps(self.graph) +
                        '\nINFO: Build completed successfully\n')
        return native_consumer.verify_action_graph(path, self.admission, self.loaded)

    def test_eight_links_bind_owned_archive_bytes(self):
        proof = self.verify()
        self.assertEqual(set(proof['links']), native_consumer.LINKS)
        self.assertEqual(len(proof['archiveInputs']), 3)
        self.assertEqual(set(proof['archiveInputs'].values()),
                         {hashlib.sha256(b'compiled lower archive').hexdigest()})

    def test_direct_bazel_json_without_wrapper_prefix(self):
        path = self.root / 'direct.json'
        path.write_text(json.dumps(self.graph) + '\nINFO: Build completed successfully\n')
        self.assertEqual(set(native_consumer.verify_action_graph(
            path, self.admission, self.loaded)['links']), native_consumer.LINKS)

    def test_omitted_link_is_rejected(self):
        self.graph['actions'].pop()
        with self.assertRaisesRegex(ValueError, 'eight Container links'):
            self.verify()

    def test_dependency_source_compile_is_rejected(self):
        self.graph['targets'].append({'id': 9, 'label': '@@' + self.name + '//:Lower'})
        self.graph['actions'].append({'targetId': 9, 'mnemonic': 'SwiftCompile'})
        with self.assertRaisesRegex(ValueError, 'source action'):
            self.verify()

    def test_unowned_archive_is_rejected(self):
        self.graph['pathFragments'][1]['label'] = '+dependencies+swiftpkg_unowned'
        with self.assertRaisesRegex(ValueError, 'unverified archive'):
            self.verify()

    def test_missing_archive_is_rejected(self):
        (self.repositories[self.name] / 'binary/libLower.a').unlink()
        with self.assertRaisesRegex(ValueError, 'escaped its verified repository'):
            self.verify()

    def test_selected_containerization_archive_is_required(self):
        index = self.names.index('+dependencies+swiftpkg_containerization') + 1
        self.graph['depSetOfFiles'][0]['directArtifactIds'].remove(index)
        with self.assertRaisesRegex(ValueError, 'selected compiled lower layer'):
            self.verify()

    def add_baseline(self):
        repository = self.name
        name = 'Lower'
        self.graph['targets'].append({'id': 9, 'label': '@@' + repository + '//:' + name})
        parts = ['bazel-out', 'darwin_arm64-opt-ST-02f1c27084ad', 'testlogs',
                 'external', repository, name, 'baseline_coverage.dat']
        parent = None
        for number, part in enumerate(parts, 100):
            row = {'id': number, 'label': part}
            if parent is not None:
                row['parentId'] = parent
            self.graph['pathFragments'].append(row)
            parent = number
        self.graph['artifacts'].append({'id': 50, 'pathFragmentId': parent})
        action = {'targetId': 9, 'mnemonic': 'BaselineCoverage',
                  'configurationId': 3, 'outputIds': [50], 'primaryOutputId': 50}
        self.graph['actions'].append(action)
        return action

    def test_coverage_baseline_metadata_is_admitted_only_in_coverage(self):
        self.add_baseline()
        path = self.root / 'coverage-aquery.json'
        path.write_text('Evidence: retained\n' + json.dumps(self.graph) +
                        '\nINFO: Build completed successfully\n')
        with self.assertRaisesRegex(ValueError, 'source action'):
            native_consumer.verify_action_graph(path, self.admission, self.loaded)
        proof = native_consumer.verify_action_graph(
            path, self.admission, self.loaded, 'runtime-coverage')
        self.assertEqual(proof['importedActions']['BaselineCoverage'], 1)
        self.assertEqual(set(proof['links']), native_consumer.LINKS)

    def test_coverage_baseline_mutations_remain_rejected(self):
        changes = (
            lambda action: action.update(mnemonic='SwiftCompile'),
            lambda action: action.update(arguments=['swiftc']),
            lambda action: action.update(inputDepSetIds=[1]),
            lambda action: action.update(outputIds=[50, 50]),
            lambda action: action.update(primaryOutputId=1),
            lambda action: self.graph['artifacts'][-1].update(isTreeArtifact=True),
            lambda action: self.graph['pathFragments'][-2].update(label='Other'),
            lambda action: self.graph['pathFragments'][-3].update(label='+dependencies+swiftpkg_other'),
            lambda action: self.graph['pathFragments'][-1].update(label='coverage.dat'),
            lambda action: self.graph['pathFragments'][-1].update(label='..'),
            lambda action: self.graph['pathFragments'][11].update(label='darwin_arm64-opt'),
        )
        for change in changes:
            with self.subTest(change=change):
                action = self.add_baseline()
                change(action)
                path = self.root / 'mutated-aquery.json'
                path.write_text('Evidence: retained\n' + json.dumps(self.graph) +
                                '\nINFO: Build completed successfully\n')
                with self.assertRaisesRegex(ValueError, 'source action'):
                    native_consumer.verify_action_graph(
                        path, self.admission, self.loaded, 'runtime-coverage')
                self.graph['targets'] = self.graph['targets'][:-1]
                self.graph['pathFragments'] = self.graph['pathFragments'][:-7]
                self.graph['artifacts'] = self.graph['artifacts'][:-1]
                self.graph['actions'] = self.graph['actions'][:-1]

    def test_staged_eight_products_must_match_successful_bep(self):
        output = self.root / 'execution'
        paths = []
        records = {}
        for label in sorted(native_consumer.LINKS):
            name = label.split('//:', 1)[1]
            relative = 'bazel-out/opt/bin/external/+dependencies+swiftpkg_container/' + name
            paths.append(relative)
            path = output / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
            records[relative] = {'sha256': hashlib.sha256(name.encode()).hexdigest(),
                                 'size': len(name)}
        receipt = {'build': {'files': records}}
        self.assertEqual(len(native_consumer.verify_staged_products(paths, output, receipt)), 8)
        (output / paths[0]).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'differs from successful'):
            native_consumer.verify_staged_products(paths, output, receipt)

    def test_unsigned_inventory_ignores_same_named_dwarf_outputs(self):
        records = {}
        for label in native_consumer.LINKS:
            name = label.split('//:', 1)[1]
            prefix = 'bazel-out/opt/bin/external/+dependencies+swiftpkg_container/'
            records[prefix + name] = {'sha256': 'a' * 64}
            records[prefix + name + '.dSYM/Contents/Resources/DWARF/' + name] = {
                'sha256': 'b' * 64}
        self.assertEqual(set(native_consumer.unsigned_product_hashes(
            {'build': {'files': records}}).values()), {'a' * 64})

    def test_prepared_reuse_survives_later_source_repository_mapping(self):
        # A subsequent source-mode unit test may repoint Bazel's mutable
        # external directory. The retained build is bound to sealed BUILD
        # bytes and raw evidence, so reuse must not consult that link again.
        for repository in self.repositories.values():
            (repository / 'BUILD.bazel').write_text('exports_files(["binary/libLower.a"])\n')
        selected = {name: hashlib.sha256((path / 'BUILD.bazel').read_bytes()).hexdigest()
                    for name, path in self.repositories.items()}
        events = self.root / 'fork-release.events.json'
        graph = self.root / 'fork-release-native-aquery.json'
        events.write_bytes(b'retained successful build')
        graph.write_bytes(b'retained action graph')
        bazel = self.root / 'bazel'
        output_root = self.root / 'output'
        command = [str(bazel), '--output_user_root=' + str(output_root), 'aquery',
                   'deps(//:container)', '--config=release', '--repo_env=GIT_COMMIT=' +
                   self.admission['source'], *native_consumer.native_layers.bazel_flags(self.admission),
                   '--output=jsonproto']
        build = {'files': {}}
        graph_record = {'layers': {}, 'loadedBUILD': selected,
                        'aquerySHA256': hashlib.sha256(graph.read_bytes()).hexdigest(),
                        'archiveInputs': {}}
        receipt = {'schema': 1, 'passed': True, 'source': self.admission['source'],
                   'configuration': 'release', 'overrides': self.admission['overrides'],
                   'recipeSHA256': 'c' * 64, 'recipeCompatibility': {},
                   'toolchain': {}, 'graph': graph_record,
                   'build': build, 'actionCommand': command,
                   'buildEventsSHA256': hashlib.sha256(events.read_bytes()).hexdigest(),
                   'actionGraphSHA256': hashlib.sha256(graph.read_bytes()).hexdigest()}
        self.admission.update(recipeSHA256='c' * 64, toolchain={})
        path = self.root / 'compiled-consumer.json'
        path.write_text(json.dumps(receipt))
        with (mock.patch.object(native_consumer.native_layers, 'verify_loaded_repositories',
                                side_effect=AssertionError('live source mapping must not be read')),
              mock.patch.object(native_consumer, 'verify_build_and_graph',
                                side_effect=lambda _events, _graph, _admission, loaded,
                                                   _revision, _configuration: {
                                    'build': build,
                                    'graph': dict(graph_record, loadedBUILD=loaded),
                                    'overrides': self.admission['overrides'],
                                    'recipeCompatibility': {}})):
            self.assertEqual(native_consumer.verify_receipt(
                path, self.admission, self.admission['source'],
                bazel=bazel, output_root=output_root), receipt)
            receipt['recipeCompatibility'] = {'foundation': {'mode': 'forged'}}
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'differs from current released layers'):
                native_consumer.verify_receipt(path, self.admission, self.admission['source'],
                                               bazel=bazel, output_root=output_root)
            receipt['recipeCompatibility'] = {}
            receipt['configuration'] = 'runtime-coverage'
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'differs from current released layers'):
                native_consumer.verify_receipt(path, self.admission, self.admission['source'],
                                               bazel=bazel, output_root=output_root)
            receipt['configuration'] = 'release'
            receipt['source'] = '0' * 40
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'differs from current released layers'):
                native_consumer.verify_receipt(path, self.admission, self.admission['source'],
                                               bazel=bazel, output_root=output_root)
            receipt['source'] = self.admission['source']
            path.write_text(json.dumps(receipt))
            (self.repositories[self.name] / 'BUILD.bazel').write_text('changed\n')
            with self.assertRaisesRegex(ValueError, 'differs from its raw build'):
                native_consumer.verify_receipt(path, self.admission, self.admission['source'],
                                               bazel=bazel, output_root=output_root)


if __name__ == '__main__':
    unittest.main()
