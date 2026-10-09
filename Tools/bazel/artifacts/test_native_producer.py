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

"""Exercise publication admission with sealed payloads and real retained schemas."""

from __future__ import annotations

import copy
import hashlib
import json
import shutil
import tarfile
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from Tools.bazel.artifacts import native_evidence, native_format, native_layers, native_producer


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + '\n')


def write_events(path, rows):
    path.write_text(''.join(json.dumps(row) + '\n' for row in rows))


def command(action, targets, root, flags):
    options = [{'optionName': 'compilation_mode', 'optionValue': 'opt' if action == 'build' else 'dbg'}]
    options += [{'optionName': flag[2:].split('=', 1)[0], 'optionValue': flag.split('=', 1)[1]}
                for flag in flags]
    return [
        {'started': {'uuid': 'fixture-' + action, 'command': action, 'workspaceDirectory': str(root)}},
        {'structuredCommandLine': {'commandLineLabel': 'canonical', 'sections': [
            {'sectionLabel': 'command', 'chunkList': {'chunk': [action]}},
            {'sectionLabel': 'command options', 'optionList': {'option': options}},
            {'sectionLabel': 'residual', 'chunkList': {'chunk': targets}}]}},
        {'finished': {'overallSuccess': True, 'exitCode': {'name': 'SUCCESS'}}},
    ]


class SealedProducerFixture:
    """No subprocess/network mocks inside the evidence or archive validators."""

    def __init__(self, directory, group='argument-parser'):
        self.directory = directory
        self.root = directory / 'source'
        self.root.mkdir()
        self.output = directory / 'producer'
        self.output.mkdir()
        self.group = group
        self.source = 'a' * 40
        self.pins = {name: {'identity': name, 'kind': 'remoteSourceControl',
                           'location': 'https://github.com/example/' + name,
                           'state': {'revision': digit * 40}}
                     for name, digit in [('swift-argument-parser', '1'), ('swift-log', '2'),
                                         ('containerization', '3'), ('container-engine-api', '4')]}
        write_json(self.root / 'Package.resolved', {'pins': list(self.pins.values())})
        (self.root / 'Package.swift').write_text('// exact source recipe\n')
        self.recipe = {'Package.swift': native_layers.digest(self.root / 'Package.swift')}
        self.inputs = {**self.recipe, 'Package.resolved': native_layers.digest(self.root / 'Package.resolved')}
        self.state = {'commit': self.source, 'dirty': False, 'recipe': self.recipe,
                      'pins': self.pins, 'toolchain': {'swiftcSHA256': 'b' * 64, 'sdkVersion': '27.0'}}
        self.current = copy.deepcopy(self.state)
        for name in ('before', 'after'):
            write_json(self.output / ('source-' + name + '.json'), self.state)
        self.lower = {'layers': {}, 'overrides': {}}
        for index, name in enumerate(native_layers.LOWER[group]):
            self.lower['layers'][name] = {
                'archiveSHA256': 'c' * 64, 'evidenceSHA256': 'd' * 64, 'proofSHA256': 'b' * 64,
                'releaseId': 100 + index, 'assetId': 200 + index, 'evidenceAssetId': 300 + index, 'proofAssetId': 400 + index,
                'lockSHA256': {'archive': 'e' * 64, 'evidence': 'f' * 64, 'proof': 'a' * 64},
                'producerCommit': self.source,
                'sourcePins': native_layers.group_pins(name, self.pins)}
        package = {'argument-parser': 'swift-argument-parser', 'foundation': 'swift-log',
                   'containerization': 'containerization', 'engine-api': 'container-engine-api'}[group]
        repo = native_layers.repo_name(package)
        modules = ('ArgumentParser', 'ArgumentParserToolInfo') if group == 'argument-parser' else ('Logging',)
        self.targets = (['@' + repo + '//:' + module + '.rspm.__impl' for module in modules]
                        if group == 'argument-parser' else ['//:container-executables'])
        self.aspect = None if group == 'argument-parser' else '//Tools/bazel/artifacts:compiled_outputs.bzl%' + group.replace('-', '_') + '_outputs'
        self.flags = ['--config=release'] + (['--macos_minimum_os=12.0'] if not self.aspect else
                                            ['--aspects=' + self.aspect, '--output_groups=layer_compiled'])
        self.events = self.output / 'source-build.events.json'
        self.build = command('build', self.targets, self.root, self.flags)
        self.members = {f'{group}/{repo}/BUILD.bazel': b'# original generated import rule\n'}
        self.payload = {}
        self.configured = {}
        files = []
        for module in modules:
            for suffix in ('.swiftmodule', '.swiftdoc', '.a'):
                name = module + suffix
                relative = f'bazel-out/darwin_arm64-opt/bin/external/+dependencies+{repo}/{name}'
                path = directory / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                content = ('compiled fixture ' + name).encode()
                path.write_bytes(content)
                member = f'{group}/{repo}/binary/{name}'
                self.members[member] = content
                self.payload[member] = relative
                self.configured[relative] = path
                files.append({'pathPrefix': ['bazel-out', 'darwin_arm64-opt', 'bin'],
                              'name': f'external/+dependencies+{repo}/{name}', 'uri': path.as_uri(),
                              'digest': native_layers.digest(path), 'length': str(len(content))})
        for target in self.targets:
            identity = {'label': target, 'configuration': {'id': 'opt-config'}}
            self.build.append({'id': {'targetCompleted': identity}, 'completed': {'success': True,
                               'outputGroup': [] if self.aspect else [{'name': 'default', 'fileSets': [{'id': 'outputs'}]}]}})
            if self.aspect:
                self.build.append({'id': {'targetCompleted': {**identity, 'aspect': self.aspect}},
                                   'completed': {'success': True, 'outputGroup': [
                                       {'name': 'layer_compiled', 'fileSets': [{'id': 'outputs'}]}]}})
        self.build.append({'id': {'namedSet': {'id': 'outputs'}}, 'namedSetOfFiles': {'files': files}})
        write_events(self.events, self.build)
        self.snapshot(self.events)
        (self.output / 'source-build.raw.log').write_text('Build completed successfully\n')
        (self.output / 'configured-outputs.raw.log').write_text('\n'.join(self.configured) + '\n')
        self.manifest = {
            'schema': 1, 'group': group, 'profile': 'native', 'graph': 'container-native',
            'configuration': 'opt', 'platform': 'darwin-arm64', 'developmentProof': False,
            'minimumMacOS': '12.0' if group == 'argument-parser' else '15.0',
            'producerCommit': self.source, 'sourcePins': native_layers.group_pins(group, self.pins),
            'recipeSHA256': self.recipe, 'toolchain': self.state['toolchain'],
            'lower': {name: native_layers.lower_identity(row) for name, row in self.lower['layers'].items()},
            'packages': {package: {'sourceCommit': self.pins[package]['state']['revision'],
                                   'sourceLocation': self.pins[package]['location'], 'repository': repo,
                                   'generatedBuildSHA256': native_format.digest(self.members[f'{group}/{repo}/BUILD.bazel'])}},
            'payloadOutputs': self.payload,
            'files': {name: native_format.digest(value) for name, value in self.members.items()}}
        self.archive = self.output / (group + '-native-darwin-arm64-opt.tar.gz')
        self.receipt_path = self.output / 'receipt.json'
        self.receipt = {
            'schema': 1, 'kind': 'q-native-compiled-layer', 'archive': str(self.archive),
            'manifest': self.manifest, 'developmentProof': False,
            'sourceBeforeSHA256': native_layers.digest(self.output / 'source-before.json'),
            'sourceAfterSHA256': native_layers.digest(self.output / 'source-after.json'),
            'sourceBuildLogSHA256': native_layers.digest(self.output / 'source-build.raw.log'),
            'sourceBuildEventsSHA256': native_layers.digest(self.events),
            'configuredOutputLogSHA256': native_layers.digest(self.output / 'configured-outputs.raw.log'),
            'buildTargets': self.targets, 'buildAspect': self.aspect, 'buildFlags': self.flags,
            'sourceBuild': native_evidence.verify_build(self.events, self.targets, self.aspect,
                                                       expected_options=self.flags),
            'sourceSnapshot': native_evidence.verify_source_snapshot(self.events, self.source, self.root, self.inputs),
            'loadedLowerBUILD': {}}
        self.seal()
        self.qualification = directory / 'qualification.json'
        self.test_events = directory / 'tests.events.json'
        required = sorted(native_evidence.GROUP_TEST_TARGETS[group])
        tests = command('test', required, self.root, [])
        reports = self.test_events.with_suffix('.tests')
        reports.mkdir()
        index = []
        for number, label in enumerate(required):
            identity = {'testResult': {'label': label, 'run': 1, 'shard': 1, 'attempt': 1,
                                       'configuration': {'id': 'dbg-config'}}}
            names = [f'{number}/test.xml', f'{number}/test.log']
            (reports / str(number)).mkdir()
            (reports / names[0]).write_text('<testsuite tests="1" failures="0"><testcase name="original-assertion"/></testsuite>')
            (reports / names[1]).write_text('Original source test passed\n')
            index.append({'id': identity, 'status': 'PASSED', 'files': names})
            tests += [{'id': identity, 'testResult': {'status': 'PASSED', 'testActionOutput': [
                {'name': Path(name).name, 'uri': (reports / name).as_uri()} for name in names]}},
                {'id': {'testSummary': identity['testResult']}, 'testSummary': {'overallStatus': 'PASSED'}}]
        write_json(reports / 'index.json', index)
        write_events(self.test_events, tests)
        self.snapshot(self.test_events)
        self.qualification_data = {'schema': 1, 'source': self.source, 'group': group, 'invocations': [
            {'events': str(self.test_events), 'eventsSHA256': native_layers.digest(self.test_events),
             'reports': {path.relative_to(reports).as_posix(): native_layers.digest(path)
                         for path in reports.rglob('*') if path.is_file()}}]}
        write_json(self.qualification, self.qualification_data)

    def snapshot(self, events):
        stem = events.name.removesuffix('.events.json')
        events.with_name(stem + '.source.txt').write_text(f'source={self.root}\nhead={self.source}\n')
        events.with_name(stem + '.diff').write_text('')
        events.with_name(stem + '.inputs.sha256').write_text(''.join(digest + '  ' + name + '\n'
                                                                  for name, digest in self.inputs.items()))

    def seal(self):
        self.manifest['files'] = {name: native_format.digest(value) for name, value in self.members.items()}
        self.archive.write_bytes(native_format.archive_bytes(self.members, self.manifest))
        self.receipt['manifest'] = self.manifest
        self.receipt['archiveSHA256'] = native_layers.digest(self.archive)
        self.save_receipt()

    def save_receipt(self):
        write_json(self.receipt_path, self.receipt)

    def plan(self, destination=None):
        destination = destination or self.directory / 'publication'
        with mock.patch.object(native_producer, 'ROOT', self.root), \
             mock.patch.object(native_producer, '_source_state', side_effect=lambda root: copy.deepcopy(self.current)), \
             mock.patch.object(native_layers, 'import_layers', return_value=copy.deepcopy(self.lower)):
            return native_producer.plan(self.receipt_path, self.qualification, destination)

    def publish(self, destination=None):
        destination = destination or self.directory / 'publication'
        with mock.patch.object(native_producer, 'ROOT', self.root), \
             mock.patch.object(native_producer, '_source_state', side_effect=lambda root: copy.deepcopy(self.current)), \
             mock.patch.object(native_layers, 'import_layers', return_value=copy.deepcopy(self.lower)):
            return native_producer.publish(self.receipt_path, self.qualification, destination)


class NativeProducerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='native-producer-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.count = 0

    def fixture(self, group='argument-parser'):
        self.count += 1
        directory = self.root / str(self.count)
        directory.mkdir()
        fixture = SealedProducerFixture(directory, group)
        # Every mutation starts from admitted bytes, preventing an unrelated
        # broken fixture from making a rejection regression falsely pass.
        fixture.plan(directory / 'baseline-plan')
        return fixture

    def rejected(self, fixture):
        with self.assertRaises((ValueError, FileNotFoundError)):
            fixture.plan()
        self.assertFalse((fixture.directory / 'publication').exists())

    def test_sealed_plan_reads_real_bep_xml_and_source_inventory(self):
        fixture = self.fixture()
        result = fixture.plan()
        self.assertEqual(result['archive']['sha256'], native_layers.digest(fixture.archive))
        self.assertEqual(result['archive']['repository'], 'stephenlclarke/container')
        evidence = json.loads((fixture.directory / 'publication/argument-parser-native-evidence.json').read_text())
        reports = evidence['qualification']['invocations'][0]['reports']
        self.assertEqual(len(reports), 2)
        self.assertTrue(all(row['executed'] == 1 and row['skipped'] == 0 for row in reports))
        self.assertNotIn(str(fixture.directory), json.dumps(evidence))
        plan = json.loads((fixture.directory / 'publication/plan.json').read_text())
        self.assertFalse(plan['published'])

    def test_plan_authenticates_archive_after_configured_outputs_expire(self):
        fixture = self.fixture()
        for path in fixture.configured.values():
            path.unlink()
        fixture.plan()

    def test_dirty_or_changed_current_source_recipe_toolchain_and_pins_rejected(self):
        for field in ('dirty', 'commit', 'recipe', 'toolchain', 'pins'):
            with self.subTest(field=field):
                fixture = self.fixture()
                fixture.current[field] = True if field == 'dirty' else ('f' * 40 if field == 'commit' else {})
                self.rejected(fixture)

    def test_changed_before_after_snapshot_rejected_even_with_updated_receipt_hash(self):
        for field in ('dirty', 'commit', 'recipe', 'toolchain', 'pins'):
            with self.subTest(field=field):
                fixture = self.fixture()
                after = copy.deepcopy(fixture.state)
                after[field] = True if field == 'dirty' else ('f' * 40 if field == 'commit' else {})
                path = fixture.output / 'source-after.json'
                write_json(path, after)
                fixture.receipt['sourceAfterSHA256'] = native_layers.digest(path)
                fixture.save_receipt()
                self.rejected(fixture)

    def test_development_receipt_or_manifest_cannot_publish(self):
        for location in ('receipt', 'manifest'):
            with self.subTest(location=location):
                fixture = self.fixture()
                getattr(fixture, location)['developmentProof'] = True
                fixture.seal()
                self.rejected(fixture)

    def test_changed_build_logs_events_query_and_source_snapshot_rejected(self):
        for suffix in ('source-build.raw.log', 'source-build.events.json', 'configured-outputs.raw.log',
                       'source-build.source.txt', 'source-build.diff', 'source-build.inputs.sha256'):
            with self.subTest(file=suffix):
                fixture = self.fixture()
                path = fixture.output / suffix
                path.write_text(path.read_text() + 'changed retained evidence\n')
                self.rejected(fixture)

    def test_rebound_failed_build_still_rejected(self):
        fixture = self.fixture()
        fixture.build[2]['finished']['overallSuccess'] = False
        write_events(fixture.events, fixture.build)
        fixture.receipt['sourceBuildEventsSHA256'] = native_layers.digest(fixture.events)
        fixture.save_receipt()
        self.rejected(fixture)

    def test_changed_test_xml_or_arbitrary_passed_hash_document_rejected(self):
        for mode in ('xml', 'passed-hashes', 'failed-xml-rebound'):
            with self.subTest(mode=mode):
                fixture = self.fixture()
                if mode == 'passed-hashes':
                    write_json(fixture.qualification, {'passed': True, 'tests': {'original': 'a' * 64}})
                else:
                    xml = fixture.test_events.with_suffix('.tests') / '0/test.xml'
                    xml.write_text('<testsuite><testcase name="original"><failure/></testcase></testsuite>')
                    if mode == 'failed-xml-rebound':
                        fixture.qualification_data['invocations'][0]['reports']['0/test.xml'] = native_layers.digest(xml)
                        write_json(fixture.qualification, fixture.qualification_data)
                self.rejected(fixture)

    def test_missing_or_unrelated_payload_mapping_rejected(self):
        for mode in ('missing', 'empty', 'unrelated'):
            with self.subTest(mode=mode):
                fixture = self.fixture()
                if mode == 'missing':
                    fixture.manifest.pop('payloadOutputs')
                elif mode == 'empty':
                    fixture.manifest['payloadOutputs'] = {}
                else:
                    member = next(iter(fixture.payload))
                    fixture.payload[member] = 'bazel-out/darwin_arm64-opt/bin/unrelated/stale.a'
                fixture.seal()
                self.rejected(fixture)

    def test_resealed_archive_wrong_binary_bytes_or_size_rejected(self):
        for mode in ('same-size', 'different-size'):
            with self.subTest(mode=mode):
                fixture = self.fixture()
                member = next(iter(fixture.payload))
                fixture.members[member] = (b'x' * len(fixture.members[member]) if mode == 'same-size' else b'x')
                fixture.seal()
                self.rejected(fixture)

    def test_tampered_recorded_build_or_missing_output_records_rejected(self):
        for mode in ('hash', 'size', 'empty', 'invocation'):
            with self.subTest(mode=mode):
                fixture = self.fixture()
                proof = fixture.receipt['sourceBuild']
                if mode == 'empty':
                    proof['files'] = {}
                elif mode == 'invocation':
                    proof['invocation'] = 'unrelated-invocation'
                else:
                    record = next(iter(proof['files'].values()))
                    record['sha256' if mode == 'hash' else 'size'] = '0' * 64 if mode == 'hash' else 1
                fixture.save_receipt()
                self.rejected(fixture)

    def test_foundation_lower_identity_and_source_pins_cannot_be_relabelled(self):
        fixture = self.fixture('foundation')
        fixture.plan()
        for mode in ('lower', 'sourcePins'):
            with self.subTest(mode=mode):
                fixture = self.fixture('foundation')
                if mode == 'lower':
                    fixture.manifest['lower']['argument-parser']['archiveSHA256'] = '0' * 64
                else:
                    fixture.manifest['sourcePins']['swift-log']['state']['revision'] = '0' * 40
                fixture.seal()
                self.rejected(fixture)

    def test_original_group_tests_cannot_be_replaced_by_another_source_or_group(self):
        for field, value in (('source', 'f' * 40), ('group', 'foundation'), ('invocations', [])):
            with self.subTest(field=field):
                fixture = self.fixture()
                fixture.qualification_data[field] = value
                write_json(fixture.qualification, fixture.qualification_data)
                self.rejected(fixture)

    def test_component_release_targets_dependency_commit_while_tests_bind_q_source(self):
        for group in ('containerization', 'engine-api'):
            with self.subTest(group=group):
                fixture = self.fixture(group)
                result = fixture.plan()
                expected = fixture.pins[native_layers.GROUP_PIN[group]]['state']['revision']
                self.assertEqual(result['archive']['targetCommit'], expected)
                sidecar = json.loads((fixture.directory / 'publication' / (group + '-native-evidence.json')).read_text())
                self.assertEqual(sidecar['source'], fixture.source)
                self.assertEqual(sidecar['qualification']['source'], fixture.source)
                self.assertEqual(set(sidecar['qualification']['requiredTargets']),
                                 native_evidence.GROUP_TEST_TARGETS[group])

    def test_changed_physical_recipe_rejected_even_if_state_claims_old_identity(self):
        fixture = self.fixture()
        (fixture.root / 'Package.swift').write_text('// changed actual bytes\n')
        self.rejected(fixture)

    def transport(self, fixture, failure=None):
        published = {}

        def upload(repository, tag, target, title, notes, assets):
            self.assertEqual(len(assets), 3)
            self.assertTrue(all(path.parent == fixture.directory / 'publication' for path in assets))
            result = {'schema': 1, 'repository': repository, 'tag': tag, 'targetCommit': target,
                      'releaseId': 123, 'assets': {path.name: {'assetId': 201 + index,
                                                           'sha256': native_layers.digest(path)}
                                                  for index, path in enumerate(assets)}}
            published.update(result)
            return result

        def download(lock_path, destination):
            self.assertFalse(destination.exists())
            lock = json.loads(lock_path.read_text())
            destination.mkdir()
            path = destination / lock['asset']
            shutil.copy2(lock_path.parent / lock['asset'], path)
            row = published['assets'][lock['asset']]
            result = {'schema': 1, 'releaseId': 123, 'assetId': row['assetId'],
                      'repository': lock['repository'], 'tag': lock['tag'],
                      'targetCommit': lock['targetCommit'], 'asset': str(path), 'sha256': lock['sha256']}
            if failure == 'bytes':
                path.write_bytes(path.read_bytes() + b'changed download')
            elif failure == 'release':
                result['releaseId'] = 999
            elif failure == 'asset':
                result['assetId'] = 999
            elif failure == 'hash':
                result['sha256'] = '0' * 64
            return result

        return upload, download

    def test_publish_revalidates_then_downloads_all_three_actual_assets(self):
        fixture = self.fixture()
        upload, download = self.transport(fixture)
        with mock.patch.object(native_producer, 'publish_assets', side_effect=upload) as publisher, \
             mock.patch.object(native_producer, 'fetch', side_effect=download) as fetch:
            result = fixture.publish()
        self.assertTrue(result['passed'])
        self.assertEqual(set(result['downloads']), {'archive', 'evidence', 'proof'})
        self.assertTrue(result['proof']['passed'])
        self.assertEqual(publisher.call_count, 1)
        self.assertEqual(fetch.call_count, 3)
        self.assertTrue((fixture.directory / 'publication/download-verification.json').is_file())
        with mock.patch.object(native_producer, 'publish_assets') as publisher:
            with self.assertRaisesRegex(ValueError, 'fresh absolute'):
                fixture.publish()
            publisher.assert_not_called()

    def test_publish_never_uploads_invalid_original_evidence(self):
        fixture = self.fixture()
        (fixture.output / 'source-build.raw.log').write_text('changed evidence')
        with mock.patch.object(native_producer, 'publish_assets') as publisher, \
             mock.patch.object(native_producer, 'fetch') as fetch:
            with self.assertRaises(ValueError):
                fixture.publish()
            publisher.assert_not_called()
            fetch.assert_not_called()

    def test_publish_download_mismatch_is_not_reported_as_verified(self):
        for failure in ('bytes', 'release', 'asset', 'hash'):
            with self.subTest(failure=failure):
                fixture = self.fixture()
                upload, download = self.transport(fixture, failure)
                with mock.patch.object(native_producer, 'publish_assets', side_effect=upload) as publisher, \
                     mock.patch.object(native_producer, 'fetch', side_effect=download):
                    with self.assertRaises(ValueError):
                        fixture.publish()
                    self.assertEqual(publisher.call_count, 1)
                self.assertFalse((fixture.directory / 'publication/download-verification.json').exists())

    def test_original_evidence_mutation_after_plan_blocks_upload(self):
        fixture = self.fixture()
        calls = 0

        def state(root):
            nonlocal calls
            calls += 1
            if calls == 2:
                (fixture.output / 'source-build.raw.log').write_text('changed after plan')
            return copy.deepcopy(fixture.current)

        with mock.patch.object(native_producer, 'ROOT', fixture.root), \
             mock.patch.object(native_producer, '_source_state', side_effect=state), \
             mock.patch.object(native_layers, 'import_layers', return_value=fixture.lower), \
             mock.patch.object(native_producer, 'publish_assets') as publisher:
            with self.assertRaisesRegex(ValueError, 'immediately before publication'):
                native_producer.publish(fixture.receipt_path, fixture.qualification,
                                        fixture.directory / 'publication')
            publisher.assert_not_called()

    def test_publish_transport_error_is_not_retried_or_overwritten(self):
        fixture = self.fixture()
        with mock.patch.object(native_producer, 'publish_assets', side_effect=ValueError('release already exists')) as publisher, \
             mock.patch.object(native_producer, 'fetch') as fetch:
            with self.assertRaisesRegex(ValueError, 'already exists'):
                fixture.publish()
            self.assertEqual(publisher.call_count, 1)
            fetch.assert_not_called()
        self.assertFalse((fixture.directory / 'publication/download-verification.json').exists())

    def test_public_proof_preserves_raw_files_and_removes_only_client_environment(self):
        fixture = self.fixture()
        secret = 'not-for-release-' + 'x' * 20
        fixture.build[1]['structuredCommandLine']['sections'][1]['optionList']['option'].append(
            {'optionName': 'client_env', 'optionValue': 'PRIVATE_VALUE=' + secret})
        fixture.build.append({'unstructuredCommandLine': {'args': ['build', '--client_env=PRIVATE_VALUE=' + secret]}})
        write_events(fixture.events, fixture.build)
        original = fixture.events.read_bytes()
        fixture.receipt['sourceBuildEventsSHA256'] = native_layers.digest(fixture.events)
        fixture.receipt['sourceBuild'] = native_evidence.verify_build(
            fixture.events, fixture.targets, expected_options=fixture.flags)
        fixture.save_receipt()
        result = fixture.plan()
        proof = fixture.directory / 'publication' / result['proof']['asset']
        sidecar = json.loads((fixture.directory / 'publication' / result['evidence']['asset']).read_text())
        self.assertTrue(native_producer.verify_proof_bundle(proof, sidecar)['passed'])
        with tarfile.open(proof, 'r:gz') as archive:
            exported = archive.extractfile('argument-parser/producer/source-build.events.json').read()
            self.assertNotIn(secret.encode(), exported)
            self.assertNotIn(b'client_env', exported)
            self.assertEqual(archive.extractfile('argument-parser/producer/source-build.raw.log').read(),
                             (fixture.output / 'source-build.raw.log').read_bytes())
        self.assertEqual(original, fixture.events.read_bytes())
        record = sidecar['proofBundle']['files']['argument-parser/producer/source-build.events.json']
        self.assertNotEqual(record['sha256'], record['originalSHA256'])
        self.assertEqual(record['normalization'], native_producer.ENV_POLICY)

    def test_public_proof_refuses_credentials_outside_environment_dump(self):
        fixture = self.fixture()
        log = fixture.output / 'source-build.raw.log'
        log.write_text('ghp_' + 'a' * 25)
        fixture.receipt['sourceBuildLogSHA256'] = native_layers.digest(log)
        fixture.save_receipt()
        with self.assertRaisesRegex(ValueError, 'credential-like'):
            fixture.plan()
        self.assertFalse((fixture.directory / 'publication/plan.json').exists())

    def test_proof_bundle_changed_bytes_or_sidecar_binding_rejected(self):
        for mode in ('bytes', 'source', 'records'):
            with self.subTest(mode=mode):
                fixture = self.fixture()
                locks = fixture.plan()
                proof = fixture.directory / 'publication' / locks['proof']['asset']
                sidecar = json.loads((fixture.directory / 'publication' / locks['evidence']['asset']).read_text())
                if mode == 'bytes':
                    proof.write_bytes(proof.read_bytes() + b'tamper')
                elif mode == 'source':
                    sidecar['source'] = 'f' * 40
                else:
                    next(iter(sidecar['proofBundle']['files'].values()))['originalSHA256'] = '0' * 64
                with self.assertRaises(ValueError):
                    native_producer.verify_proof_bundle(proof, sidecar)

    def test_normalized_test_bep_still_enforces_source_mode_and_summary_gates(self):
        for mode in ('filter', 'test-arg', 'override', 'opt', 'repeat', 'summary-failed', 'configuration'):
            with self.subTest(mode=mode):
                fixture = self.fixture()
                rows = [json.loads(line) for line in fixture.test_events.read_text().splitlines()]
                rows[1]['structuredCommandLine']['sections'][1]['optionList']['option'].append(
                    {'optionName': 'client_env', 'optionValue': 'HOME=/original/private/location'})
                write_events(fixture.test_events, rows)
                fixture.qualification_data['invocations'][0]['eventsSHA256'] = native_layers.digest(fixture.test_events)
                write_json(fixture.qualification, fixture.qualification_data)
                locks = fixture.plan()
                proof = fixture.directory / 'publication' / locks['proof']['asset']
                sidecar = json.loads((fixture.directory / 'publication' / locks['evidence']['asset']).read_text())
                manifest = native_format.inspect(proof)['manifest']
                with tarfile.open(proof, 'r:gz') as archive:
                    members = {name: archive.extractfile(name).read() for name in manifest['files']}
                member = manifest['invocations'][0]['events']
                exported = [json.loads(line) for line in members[member].splitlines()]
                options = exported[1]['structuredCommandLine']['sections'][1]['optionList']['option']
                if mode == 'opt':
                    options[0]['optionValue'] = 'opt'
                elif mode in ('summary-failed', 'configuration'):
                    summary = next(row for row in exported if 'testSummary' in row)
                    if mode == 'summary-failed':
                        summary['testSummary']['overallStatus'] = 'FAILED'
                    else:
                        summary['id']['testSummary']['configuration'] = {'id': 'different'}
                else:
                    name, value = {'filter': ('test_filter', 'one-case'), 'test-arg': ('test_arg', '--skip'),
                                   'override': ('override_repository', 'dep=/prebuilt'),
                                   'repeat': ('runs_per_test', '2')}[mode]
                    options.append({'optionName': name, 'optionValue': value})
                members[member] = ''.join(json.dumps(row) + '\n' for row in exported).encode()
                digest = hashlib.sha256(members[member]).hexdigest()
                manifest['files'][member] = digest
                manifest['records'][member].update(sha256=digest, size=len(members[member]))
                proof.write_bytes(native_format.archive_bytes(members, manifest))
                sidecar['proofBundle'].update(sha256=native_layers.digest(proof), files=manifest['records'],
                    manifestSHA256=hashlib.sha256((json.dumps(manifest, sort_keys=True,
                                                             separators=(',', ':')) + '\n').encode()).hexdigest())
                with self.assertRaisesRegex(ValueError, 'source mode|summaries'):
                    native_producer.verify_proof_bundle(proof, sidecar)

    def test_qualify_uses_exact_original_source_targets_and_copies_verified_reports(self):
        fixture = self.fixture()
        log = fixture.test_events.with_name('tests.log')
        log.write_text('Original unit tests passed\n')
        output = fixture.directory / 'qualification-run'
        with mock.patch.object(native_producer, '_source_state', return_value=fixture.current), \
             mock.patch.object(native_producer, '_run_bazel', return_value=('', log)) as runner:
            proof = native_producer.qualify('argument-parser', output, root=fixture.root)
        call = runner.call_args.args
        self.assertEqual(call[:4], (fixture.root, 'test', [],
                                   sorted(native_evidence.GROUP_TEST_TARGETS['argument-parser'])))
        self.assertTrue(proof['passed'])
        document = json.loads((output / 'qualification.json').read_text())
        self.assertEqual(Path(document['invocations'][0]['events']).parent, output)
        self.assertTrue((output / 'qualification.events.tests/0/test.xml').is_file())
        self.assertEqual((output / 'tests.raw.log').read_bytes(), log.read_bytes())

    def test_qualify_dirty_or_changed_source_never_writes_passed_proof(self):
        for phase in ('before', 'after'):
            with self.subTest(phase=phase):
                fixture = self.fixture()
                bad = {**fixture.current, 'dirty': True}
                states = [bad] if phase == 'before' else [fixture.current, bad]
                log = fixture.test_events.with_name('tests.log')
                log.write_text('Original unit tests passed\n')
                output = fixture.directory / 'qualification-run'
                with mock.patch.object(native_producer, '_source_state', side_effect=states), \
                     mock.patch.object(native_producer, '_run_bazel', return_value=('', log)) as runner:
                    with self.assertRaises(ValueError):
                        native_producer.qualify('argument-parser', output, root=fixture.root)
                    self.assertEqual(runner.call_count, 0 if phase == 'before' else 1)
                self.assertFalse((output / 'qualification-proof.json').exists())


if __name__ == '__main__':
    unittest.main()
