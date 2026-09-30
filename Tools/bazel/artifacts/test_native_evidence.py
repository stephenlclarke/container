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

"""Publication evidence regressions with real Bazel event shapes."""

from __future__ import annotations

import ast
import json
from pathlib import Path
import tempfile
import unittest

try:
    from . import native_evidence as evidence
except ImportError:
    import native_evidence as evidence


class NativeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.events_path = self.root / 'proof.events.json'
        self.source = 'a' * 40
        self.aspect = '//Tools/bazel/artifacts:compiled_outputs.bzl%foundation_outputs'
        self.targets = ['@swiftpkg_swift_argument_parser//:ArgumentParser.rspm.__impl']
        self.relative = 'bazel-out/darwin_arm64-opt/bin/external/+dependencies+swiftpkg_swift_argument_parser/ArgumentParser.swiftmodule'
        self.binary = self.root / self.relative
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b'actual compiled bytes')

    def option(self, name, value):
        return {'optionName': name, 'optionValue': value, 'combinedForm': '--' + name + '=' + value}

    def command(self, action, targets, extra=()):
        options = [self.option('compilation_mode', 'opt' if action == 'build' else 'dbg')]
        if action == 'build':
            options.append(self.option('config', 'release'))
        options.extend(extra)
        return [
            {'id': {'started': {}}, 'started': {'uuid': 'retained-invocation', 'command': action,
                                               'workspaceDirectory': str(self.root)}},
            {'structuredCommandLine': {'commandLineLabel': 'canonical', 'sections': [
                {'sectionLabel': 'command', 'chunkList': {'chunk': [action]}},
                {'sectionLabel': 'command options', 'optionList': {'option': options}},
                {'sectionLabel': 'residual', 'chunkList': {'chunk': targets}},
            ]}},
            {'finished': {'overallSuccess': True, 'exitCode': {'name': 'SUCCESS'}}},
        ]

    def write_events(self, rows):
        self.events_path.write_text(''.join(json.dumps(row) + '\n' for row in rows))

    def build_rows(self, aspect=False):
        extra = [self.option('aspects', self.aspect), self.option('output_groups', '+layer_compiled')] if aspect else []
        rows = self.command('build', self.targets, extra)
        label = '@@+dependencies+swiftpkg_swift_argument_parser//:ArgumentParser.rspm.__impl'
        completed = {'id': {'targetCompleted': {'label': label, 'configuration': {'id': 'retained-config'}}},
                     'completed': {'success': True, 'outputGroup': [{'name': 'default', 'fileSets': [{'id': '0'}]}]}}
        rows.append(completed)
        if aspect:
            rows.append({'id': {'targetCompleted': {'label': label, 'aspect': self.aspect,
                                                        'configuration': {'id': 'retained-config'}}},
                         'completed': {'success': True, 'outputGroup': [{'name': 'layer_compiled', 'fileSets': [{'id': '0'}]}]}})
        rows.extend([
            {'id': {'namedSet': {'id': '0'}}, 'namedSetOfFiles': {'fileSets': [{'id': '1'}]}},
            {'id': {'namedSet': {'id': '1'}}, 'namedSetOfFiles': {'files': [{
                'pathPrefix': ['bazel-out', 'darwin_arm64-opt', 'bin'],
                'name': 'external/+dependencies+swiftpkg_swift_argument_parser/ArgumentParser.swiftmodule',
                'uri': self.binary.as_uri(), 'digest': evidence._sha(self.binary),
                'length': str(self.binary.stat().st_size),
            }]}},
        ])
        return rows

    def verify_build(self, rows, aspect=False, **kwargs):
        self.write_events(rows)
        flags = ['--config=release']
        if aspect:
            flags += ['--aspects=' + self.aspect, '--output_groups=+layer_compiled']
        return evidence.verify_build(self.events_path, self.targets, self.aspect if aspect else None,
                                     {self.relative: self.binary}, expected_options=flags, **kwargs)

    def test_build_reads_recursive_successful_output_and_returns_safe_projection(self):
        for aspect in (False, True):
            result = self.verify_build(self.build_rows(aspect), aspect)
            self.assertEqual(result['files'][self.relative]['sha256'], evidence._sha(self.binary))
            self.assertNotIn(str(self.root), json.dumps(result))

    def test_lower_only_and_default_plus_lower_require_exact_intended_selection(self):
        for actual in ('layer_compiled', '+layer_compiled'):
            for intended in ('layer_compiled', '+layer_compiled'):
                with self.subTest(actual=actual, intended=intended):
                    rows = self.build_rows(True)
                    options = rows[1]['structuredCommandLine']['sections'][1]['optionList']['option']
                    option = next(x for x in options if x['optionName'] == 'output_groups')
                    option.update(self.option('output_groups', actual))
                    self.write_events(rows)
                    flags = ['--config=release', '--aspects=' + self.aspect,
                             '--output_groups=' + intended]
                    if actual == intended:
                        result = evidence.verify_build(self.events_path, self.targets, self.aspect,
                                                       expected_options=flags)
                        self.assertIn(self.relative, result['files'])
                    else:
                        with self.assertRaises(ValueError):
                            evidence.verify_build(self.events_path, self.targets, self.aspect,
                                                  expected_options=flags)

    def test_aspect_cannot_infer_output_selection_from_observed_events(self):
        self.write_events(self.build_rows(True))
        for flags in (None, ['--config=release', '--aspects=' + self.aspect],
                      ['--config=release', '--aspects=' + self.aspect, '--output_groups=default']):
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                evidence.verify_build(self.events_path, self.targets, self.aspect,
                                      expected_options=flags)

    def test_retained_record_survives_expired_outputs_without_claiming_verified_bytes(self):
        self.write_events(self.build_rows(True))
        flags = ['--config=release', '--aspects=' + self.aspect, '--output_groups=+layer_compiled']
        sealed = evidence.verify_build(self.events_path, self.targets, self.aspect,
                                       expected_options=flags)
        self.binary.write_bytes(b'different later build')
        self.assertEqual(evidence.verify_build_record(self.events_path, self.targets, self.aspect,
                                                      expected_options=flags), sealed)
        with self.assertRaisesRegex(ValueError, 'digest or size'):
            evidence.verify_build(self.events_path, self.targets, self.aspect, expected_options=flags)
        self.binary.unlink()
        self.assertEqual(evidence.verify_build_record(self.events_path, self.targets, self.aspect,
                                                      expected_options=flags), sealed)
        with self.assertRaises(FileNotFoundError):
            evidence.verify_build(self.events_path, self.targets, self.aspect, expected_options=flags)

    def test_retained_record_keeps_terminal_selection_and_digest_guards(self):
        for mode in ('failure', 'target', 'selection', 'digest', 'options'):
            with self.subTest(mode=mode):
                rows = self.build_rows(True)
                flags = ['--config=release', '--aspects=' + self.aspect, '--output_groups=+layer_compiled']
                if mode == 'failure':
                    rows[2]['finished']['overallSuccess'] = False
                elif mode == 'target':
                    rows[4]['completed']['success'] = False
                elif mode == 'selection':
                    flags[-1] = '--output_groups=layer_compiled'
                elif mode == 'digest':
                    rows[-1]['namedSetOfFiles']['files'][0].pop('digest')
                else:
                    flags = None
                self.write_events(rows)
                with self.assertRaises(ValueError):
                    evidence.verify_build_record(self.events_path, self.targets, self.aspect,
                                                 expected_options=flags)

    def test_stale_cquery_file_outside_successful_closure_rejected(self):
        rows = self.build_rows()
        self.write_events(rows)
        other = self.binary.with_name('stale.swiftmodule')
        other.write_bytes(self.binary.read_bytes())
        with self.assertRaisesRegex(ValueError, 'not an output'):
            evidence.verify_build(self.events_path, self.targets,
                                  required_files={self.relative.replace('ArgumentParser', 'stale'): other})

    def test_changed_payload_digest_and_size_rejected(self):
        for payload in (b'changed same byte siz!', b'longer changed file contents'):
            rows = self.build_rows()
            self.binary.write_bytes(payload)
            with self.assertRaisesRegex(ValueError, 'digest or size'):
                self.verify_build(rows)

    def test_failed_missing_duplicate_target_and_aspect_rejected(self):
        for mode in ('failed', 'missing', 'duplicate', 'aspect_failed', 'aspect_missing'):
            with self.subTest(mode=mode):
                rows = self.build_rows(True)
                if mode == 'failed':
                    rows[3]['completed']['success'] = False
                elif mode == 'missing':
                    rows.pop(3)
                elif mode == 'duplicate':
                    rows.append(rows[3])
                elif mode == 'aspect_failed':
                    rows[4]['completed']['success'] = False
                else:
                    rows.pop(4)
                with self.assertRaises(ValueError):
                    self.verify_build(rows, True)

    def test_missing_cyclic_duplicate_sets_and_unsafe_uri_rejected(self):
        for mode in ('missing', 'cycle', 'duplicate', 'unsafe', 'digest'):
            with self.subTest(mode=mode):
                rows = self.build_rows()
                if mode == 'missing':
                    rows.pop()
                elif mode == 'cycle':
                    rows[-1]['namedSetOfFiles']['fileSets'] = [{'id': '0'}]
                elif mode == 'duplicate':
                    rows.append(rows[-1])
                elif mode == 'unsafe':
                    rows[-1]['namedSetOfFiles']['files'][0]['uri'] = 'https://example.invalid/artifact'
                else:
                    rows[-1]['namedSetOfFiles']['files'][0].pop('digest')
                with self.assertRaises(ValueError):
                    self.verify_build(rows)

    def test_wrong_command_config_targets_and_unexpected_override_rejected(self):
        for mode in ('action', 'target', 'config', 'override', 'unfinished'):
            with self.subTest(mode=mode):
                rows = self.build_rows()
                if mode == 'action':
                    rows[0]['started']['command'] = 'cquery'
                elif mode == 'target':
                    rows[1]['structuredCommandLine']['sections'][-1]['chunkList']['chunk'] = ['//:other']
                elif mode == 'config':
                    rows[1]['structuredCommandLine']['sections'][1]['optionList']['option'][0]['optionValue'] = 'dbg'
                elif mode == 'override':
                    rows[1]['structuredCommandLine']['sections'][1]['optionList']['option'].append(self.option('override_repository', 'repo=/elsewhere'))
                else:
                    rows.pop(2)
                with self.assertRaises(ValueError):
                    self.verify_build(rows)

    def qualification(self):
        labels = sorted(evidence.GROUP_TEST_TARGETS['argument-parser'])
        rows = self.command('test', ['//:argument-parser-tests'])
        directory = self.events_path.with_suffix('.tests')
        directory.mkdir(exist_ok=True)
        index = []
        for number, label in enumerate(labels):
            canonical = '@@+dependencies+' + label.removeprefix('@')
            identity = {'testResult': {'label': canonical, 'run': 1, 'shard': 1, 'attempt': 1,
                                       'configuration': {'id': 'test-configuration'}}}
            files = [f'{number}/test.log', f'{number}/test.xml']
            for name in files:
                file = directory / name
                file.parent.mkdir(exist_ok=True)
                file.write_text('test passed\n' if name.endswith('.log') else
                                '<testsuites><testsuite name="real-suite"><testcase name="executed"/>'
                                '<testcase name="host-only"><skipped message="CI host requirement"/>'
                                '</testcase></testsuite></testsuites>')
            index.append({'id': identity, 'status': 'PASSED', 'files': files})
            rows.append({'id': identity, 'testResult': {'status': 'PASSED', 'cachedLocally': True,
                         'testActionOutput': [{'name': Path(n).name, 'uri': (directory / n).as_uri()} for n in files]}})
            rows.append({'id': {'testSummary': json.loads(json.dumps(identity['testResult']))},
                         'testSummary': {'overallStatus': 'PASSED', 'totalRunCount': 1}})
        (directory / 'index.json').write_text(json.dumps(index))
        self.write_events(rows)
        (self.root / 'Package.resolved').write_text('source-bound recipe\n')
        inputs = {'Package.resolved': evidence._sha(self.root / 'Package.resolved')}
        self.events_path.with_name('proof.source.txt').write_text(f'source={self.root}\nhead={self.source}\nProductName: macOS\n')
        self.events_path.with_name('proof.diff').write_text('')
        self.events_path.with_name('proof.inputs.sha256').write_text(inputs['Package.resolved'] + '  Package.resolved\n')
        self.qualification_path = self.root / 'qualification.json'
        document = {'schema': 1, 'source': self.source, 'group': 'argument-parser', 'invocations': [{
            'events': str(self.events_path), 'eventsSHA256': evidence._sha(self.events_path),
            'reports': {p.relative_to(directory).as_posix(): evidence._sha(p) for p in directory.rglob('*') if p.is_file()},
        }]}
        self.qualification_path.write_text(json.dumps(document))
        return rows, document, inputs

    def check_qualification(self, document, inputs, rows=None):
        if rows is not None:
            self.write_events(rows)
            document['invocations'][0]['eventsSHA256'] = evidence._sha(self.events_path)
        self.qualification_path.write_text(json.dumps(document))
        return evidence.verify_qualification(self.qualification_path, self.source, 'argument-parser',
                                             source_root=self.root, expected_inputs=inputs)

    def test_actual_retained_index_shape_passes_and_preserves_skips(self):
        _, document, inputs = self.qualification()
        result = self.check_qualification(document, inputs)
        self.assertTrue(result['passed'])
        self.assertEqual([r['executed'] for r in result['invocations'][0]['reports']], [1, 1])
        self.assertEqual([r['skipped'] for r in result['invocations'][0]['reports']], [1, 1])
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_arbitrary_passed_hash_map_does_not_qualify(self):
        _, _, inputs = self.qualification()
        with self.assertRaises(ValueError):
            self.check_qualification({'schema': 1, 'source': self.source, 'group': 'argument-parser',
                                      'passed': True, 'tests': {'fake': 'b' * 64}}, inputs)

    def test_changed_report_and_bep_rejected(self):
        for name in ('events', 'xml', 'index'):
            with self.subTest(name=name):
                _, document, inputs = self.qualification()
                file = (self.events_path if name == 'events' else
                        self.events_path.with_suffix('.tests') / ('0/test.xml' if name == 'xml' else 'index.json'))
                file.write_text(file.read_text() + '\n')
                with self.assertRaises(ValueError):
                    self.check_qualification(document, inputs)

    def test_missing_failed_duplicate_filtered_and_retried_tests_rejected(self):
        for mode in ('missing', 'failed', 'duplicate', 'filter', 'retry'):
            with self.subTest(mode=mode):
                rows, document, inputs = self.qualification()
                if mode == 'missing':
                    rows.pop()
                elif mode == 'failed':
                    rows[-1]['testSummary']['overallStatus'] = 'FAILED'
                elif mode == 'duplicate':
                    rows.append(rows[-1])
                elif mode == 'filter':
                    rows[1]['structuredCommandLine']['sections'][1]['optionList']['option'].append(self.option('test_filter', 'one'))
                else:
                    rows[3]['id']['testResult']['attempt'] = 2
                with self.assertRaises(ValueError):
                    self.check_qualification(document, inputs, rows)

    def test_wrong_source_dirty_snapshot_recipe_drift_rejected(self):
        for mode in ('source', 'diff', 'status', 'inputs', 'recipe'):
            with self.subTest(mode=mode):
                _, document, inputs = self.qualification()
                if mode == 'source':
                    document['source'] = 'c' * 40
                elif mode == 'diff':
                    self.events_path.with_name('proof.diff').write_text('modified source')
                elif mode == 'status':
                    with self.events_path.with_name('proof.source.txt').open('a') as file:
                        file.write('?? untracked.py\n')
                elif mode == 'inputs':
                    (self.root / 'Package.resolved').write_text('changed')
                else:
                    inputs['Package.resolved'] = 'c' * 64
                with self.assertRaises(ValueError):
                    self.check_qualification(document, inputs)

    def test_empty_failed_and_all_skipped_xml_rejected_even_with_updated_digest(self):
        for xml in ('<testsuites/>', '<testsuite><testcase><failure/></testcase></testsuite>',
                    '<testsuite><testcase><skipped/></testcase></testsuite>',
                    '<testsuite><testcase status="notrun"/></testsuite>'):
            _, document, inputs = self.qualification()
            path = self.events_path.with_suffix('.tests') / '0/test.xml'
            path.write_text(xml)
            document['invocations'][0]['reports']['0/test.xml'] = evidence._sha(path)
            with self.assertRaises(ValueError):
                self.check_qualification(document, inputs)

    def test_wrong_payload_path_and_duplicate_payload_identity_rejected(self):
        rows = self.build_rows()
        rows[-1]['namedSetOfFiles']['files'].append(rows[-1]['namedSetOfFiles']['files'][0])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.verify_build(rows)
        rows = self.build_rows()
        self.write_events(rows)
        other = self.root / 'not-the-built-output'
        other.write_bytes(self.binary.read_bytes())
        with self.assertRaises(ValueError):
            evidence.verify_build(self.events_path, self.targets,
                                  required_files={self.relative: other})

    def test_aspect_configuration_and_producer_minimum_are_bound(self):
        rows = self.build_rows(True)
        rows[4]['id']['targetCompleted']['configuration'] = {'id': 'other-config'}
        with self.assertRaisesRegex(ValueError, 'configuration'):
            self.verify_build(rows, True)
        rows = self.build_rows()
        rows[1]['structuredCommandLine']['sections'][1]['optionList']['option'].append(self.option('macos_minimum_os', '15.0'))
        self.write_events(rows)
        with self.assertRaisesRegex(ValueError, 'option differs'):
            evidence.verify_build(self.events_path, self.targets,
                                  expected_options=['--config=release', '--macos_minimum_os=12.0'])

    def test_duplicate_invocation_cannot_retry_a_group(self):
        _, document, inputs = self.qualification()
        document['invocations'].append(document['invocations'][0])
        with self.assertRaisesRegex(ValueError, 'repeated'):
            self.check_qualification(document, inputs)

    def test_report_configuration_and_forwarded_test_filter_are_bound(self):
        rows, document, inputs = self.qualification()
        rows[-1]['id']['testSummary']['configuration'] = {'id': 'other-config'}
        with self.assertRaises(ValueError):
            self.check_qualification(document, inputs, rows)
        rows, document, inputs = self.qualification()
        rows[1]['structuredCommandLine']['sections'][1]['optionList']['option'].append(self.option('test_arg', '--filter=one'))
        with self.assertRaisesRegex(ValueError, 'unfiltered'):
            self.check_qualification(document, inputs, rows)

    def test_absent_invocation_and_unknown_report_cannot_be_hash_only_proofs(self):
        _, document, inputs = self.qualification()
        document['invocations'][0]['events'] = str(self.root / 'absent.events.json')
        with self.assertRaises(ValueError):
            self.check_qualification(document, inputs)
        _, document, inputs = self.qualification()
        path = self.events_path.with_suffix('.tests') / 'unused.log'
        path.write_text('unused')
        document['invocations'][0]['reports']['unused.log'] = evidence._sha(path)
        with self.assertRaisesRegex(ValueError, 'unreferenced'):
            self.check_qualification(document, inputs)

    def test_finite_inventory_matches_maintained_layer_declarations(self):
        layers = Path(__file__).resolve().parents[1] / 'layers.bzl'
        tree = ast.parse(layers.read_text())
        node = next(n.value for n in tree.body if isinstance(n, ast.Assign)
                    and any(isinstance(t, ast.Name) and t.id == 'LAYERS' for t in n.targets))
        actual = {}
        for key, value in zip(node.keys, node.values):
            fields = {k.arg: ast.literal_eval(k.value) for k in value.keywords}
            if fields['package'] != 'container' and fields['tests']:
                actual[ast.literal_eval(key)] = (fields['package'], tuple(fields['tests']))
        self.assertEqual(evidence.TEST_LAYERS, actual)
        self.assertEqual({g: len(v) for g, v in evidence.GROUP_TEST_TARGETS.items()},
                         {'argument-parser': 2, 'foundation': 49, 'containerization': 10, 'engine-api': 9})


if __name__ == '__main__':
    unittest.main()
