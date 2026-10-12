"""VM integration keeps nonempty results, failures and platform skips distinct."""

from pathlib import Path
import hashlib
import json
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from vm_integration import (GPU_SKIP_REASON, retain_results, stage_runc, validate_skips,
                            vm_build_plan, verify_vm_actions, compile_vm_tools, private_child, remove_run_home)


class VMResultsTests(unittest.TestCase):
    def test_vm_plan_imports_only_lower_prefix_and_matches_guest(self):
        admission = {'layers': {'argument-parser': {}, 'foundation': {}},
                     'overrides': {'+dependencies+swiftpkg_swift_log': '/verified/log'}}
        pins = {'containerization': {'state': {'revision': 'a' * 40}}}
        with patch('vm_integration.native_layers.import_layers', return_value=admission) as imported, \
                patch('vm_integration.native_layers.pin_records', return_value=pins):
            labels, flags, observed = vm_build_plan(Path('/repo'), 'a' * 40)
            imported.assert_called_once_with(Path('/repo'), groups=('foundation',))
            self.assertIs(observed, admission)
            self.assertEqual(len(labels), 2)
            self.assertEqual(flags, ['--config=release',
                             '--override_repository=+dependencies+swiftpkg_swift_log=/verified/log'])
            with self.assertRaisesRegex(ValueError, 'guest source'):
                vm_build_plan(Path('/repo'), 'b' * 40)
            admission['overrides']['+dependencies+swiftpkg_containerization'] = '/wrong/sdk'
            with self.assertRaisesRegex(ValueError, 'source-built SDK'):
                vm_build_plan(Path('/repo'), 'a' * 40)

    def test_vm_graph_rejects_lower_source_fallback_and_missing_tool(self):
        admission = {'overrides': {'+dependencies+swiftpkg_swift_log': '/verified/log'}}
        loaded = {'+dependencies+swiftpkg_swift_log': 'digest'}
        targets = [{'id': 1, 'label': '@@+dependencies+swiftpkg_containerization//:cctl.rspm.__impl'},
                   {'id': 2, 'label': '@@+dependencies+swiftpkg_containerization//:containerization-integration.rspm.__impl'},
                   {'id': 3, 'label': '@@+dependencies+swiftpkg_swift_log//:Logging.rspm.__impl'}]
        graph = {'targets': targets, 'actions': [{'targetId': 1, 'mnemonic': 'CppLink'},
                                                {'targetId': 2, 'mnemonic': 'CppLink'},
                                                {'targetId': 1, 'mnemonic': 'SwiftCompile'},
                                                {'targetId': 3, 'mnemonic': 'FileWrite'}]}
        self.assertEqual(verify_vm_actions(graph, admission, loaded)['sdkCompileActions'], 1)
        for action in [{'targetId': 3, 'mnemonic': 'SwiftCompile'},
                       {'targetId': 3, 'mnemonic': 'CppCompile'},
                       {'targetId': 99, 'mnemonic': 'SwiftCompile'},
                       {'targetId': 1, 'mnemonic': 'CppLink'}]:
            with self.subTest(action=action), self.assertRaises(ValueError):
                verify_vm_actions(dict(graph, actions=graph['actions'] + [action]), admission, loaded)
        for missing in (0, 1, 2):
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                verify_vm_actions(dict(graph, actions=[row for i, row in enumerate(graph['actions'])
                                                       if i != missing]), admission, loaded)
        with self.assertRaisesRegex(ValueError, 'loaded repository'):
            verify_vm_actions(graph, admission, {})
        targets[2]['label'] = '@@+dependencies+swiftpkg_swift_nio//:NIO.rspm.__impl'
        with self.assertRaisesRegex(ValueError, 'source action'):
            verify_vm_actions(graph, admission, loaded)

    def test_vm_build_uses_identical_verified_flags_and_binds_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            flags = ['--config=release', '--override_repository=+dependencies+swiftpkg_swift_log=/verified/log']
            labels = ['@swiftpkg_containerization//:' + name + '.rspm'
                      for name in ('cctl', 'containerization-integration')]
            admission = {'source': 'c' * 40, 'layers': {}, 'overrides': {}, 'recipeSHA256': {}}
            for name in ('vm_integration.py', 'test_vm_integration.py'):
                file = root / 'Tools/bazel' / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('harness')
            commands = []
            failure = {'fixture': None, 'ambiguous': False, 'no_evidence': False}

            class FakeRunner:
                def run(self, _component, _lane, fixture, _trial, args, _cwd, _timeout):
                    commands.append(args)
                    log = root / (fixture + '.log')
                    if fixture == 'build':
                        raw = root / 'raw.log'
                        for suffix in ('.log', '.events.json', '.source.txt', '.diff', '.inputs.sha256'):
                            raw.with_suffix(suffix).write_text('retained ' + suffix)
                        log.write_text('missing evidence' if failure['no_evidence'] else 'Evidence: ' + str(raw) + '\n')
                    elif fixture.startswith('query-'):
                        name = fixture.removeprefix('query-')
                        relative = 'bazel-out/opt/bin/' + name + '.rspm.__impl'
                        binary = root / relative
                        binary.parent.mkdir(parents=True, exist_ok=True)
                        binary.write_bytes(name.encode())
                        log.write_text(relative + '\n' + (relative + '\n' if failure['ambiguous'] else ''))
                    else:
                        log.write_text('action graph')
                    return {'status': int(fixture == failure['fixture']), 'log': str(log)}

            with patch('vm_integration.ROOT', root), \
                    patch('vm_integration.vm_build_plan', return_value=(labels, flags, admission)), \
                    patch('vm_integration.checked', return_value=str(root)), \
                    patch('vm_integration.native_layers.verify_loaded_repositories', return_value={}), \
                    patch('vm_integration.native_evidence.verify_build', return_value={'passed': True}) as build, \
                    patch('vm_integration.native_evidence.verify_source_snapshot', return_value={'passed': True}) as snapshot, \
                    patch('vm_integration.native_consumer._graph', return_value={}), \
                    patch('vm_integration.verify_vm_actions', return_value={'passed': True}):
                observed = compile_vm_tools(FakeRunner(), root, 'a' * 40)
                self.assertEqual(set(observed), {'cctl', 'containerization-integration'})
                self.assertEqual(build.call_args.kwargs['expected_options'], flags)
                self.assertEqual(snapshot.call_args.args[1:3], ('c' * 40, root))
                self.assertEqual(set(snapshot.call_args.args[3]),
                                 {'Tools/bazel/vm_integration.py', 'Tools/bazel/test_vm_integration.py'})
                self.assertEqual(set(build.call_args.kwargs['required_files'].values()), set(observed.values()))
                for command in commands:
                    self.assertIn(flags[0], command)
                    self.assertIn(flags[1], command)
                proof = json.loads((root / 'vm-build.json').read_text())
                self.assertTrue(proof['passed'])
                self.assertEqual(proof['unsignedBinaries']['cctl'], hashlib.sha256(b'cctl').hexdigest())
                for fixture in ('build', 'query-cctl', 'action-graph'):
                    failure['fixture'] = fixture
                    with self.subTest(fixture=fixture), self.assertRaises(RuntimeError):
                        compile_vm_tools(FakeRunner(), root, 'a' * 40)
                failure['fixture'] = None
                for field in ('ambiguous', 'no_evidence'):
                    failure[field] = True
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        compile_vm_tools(FakeRunner(), root, 'a' * 40)
                    failure[field] = False

    def test_vm_state_paths_reject_redirection_and_require_marked_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / 'outside'
            outside.mkdir()
            parent = root / 'installation'
            parent.mkdir()
            (parent / 'bin').symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, 'private owned'):
                private_child(parent, 'bin')
            (parent / 'bin').unlink()
            (parent / 'bin').write_text('file')
            with self.assertRaisesRegex(RuntimeError, 'private owned'):
                private_child(parent, 'bin')
            with self.assertRaisesRegex(RuntimeError, 'private owned'):
                private_child(parent, '../outside')
            home = private_child(parent, 'run-test')
            private_child(home, 'tmp')
            with self.assertRaisesRegex(RuntimeError, 'escaped'):
                remove_run_home(parent, outside)
            with self.assertRaisesRegex(RuntimeError, 'ownership marker'):
                remove_run_home(parent, home)
            marker = home / '.runtime-benchmark-owner.json'
            marker.write_text(json.dumps({'owner': 'container-runtime-benchmark',
                                         'lane': 'containerization-integration-state', 'schema': 1}))
            remove_run_home(parent, home)
            self.assertFalse(home.exists())
            self.assertTrue(outside.exists())

    def test_failures_and_skips_remain_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'run.log'
            log.write_text('test boot complete in 4.5e-05s.\n'
                           'test exec failed: wrong exit status\n'
                           'test graphics started...\n'
                           'skipped test: GPU unavailable\n'
                           'Integration suite completed in 1.0s with 1/3 passed and 1/3 skipped!\n')
            result = retain_results(log, root)
            self.assertEqual(result, {'passed_tests': 1, 'total_tests': 3, 'skipped_tests': 1,
                                     'skips': [{'test': 'graphics', 'reason': 'GPU unavailable'}]})
            xml = ET.parse(root / 'tests.xml')
            self.assertEqual(len(list(xml.iter('failure'))), 1)
            self.assertEqual(len(list(xml.iter('skipped'))), 1)
            self.assertEqual(list(xml.iter('testcase'))[0].get('time'), '4.5e-05')
            log.write_text('Integration suite completed in 0.0s with 0/0 passed!')
            with self.assertRaisesRegex(RuntimeError, 'nonempty'):
                retain_results(log, root)

    def test_summary_cannot_hide_missing_individual_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'run.log'
            log.write_text('test boot complete in 0.45s.\n'
                           'Integration suite completed in 1.0s with 2/2 passed!\n')
            with self.assertRaisesRegex(RuntimeError, 'disagree'):
                retain_results(log, root)

    def test_only_named_unsupported_graphics_skips_are_accepted(self):
        allowed = {'test': 'container virtio graphics device attachment', 'reason': GPU_SKIP_REASON}
        validate_skips({'skips': [allowed]})
        for skip in [dict(allowed, test='runc process true'), dict(allowed, reason='bin/runc-arm64 missing')]:
            with self.subTest(skip=skip), self.assertRaisesRegex(RuntimeError, 'skipped required tests'):
                validate_skips({'skips': [skip]})

    def test_vm_host_fixture_must_match_runc_guest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'runc'
            binary.write_bytes(b'runtime')
            sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            pin = {'version': 'v1.5.1', 'sha256': sha}
            guest = {'identity': {'runc': pin}, 'runc_binary': str(binary), 'binaries': {'runc': sha}}
            destination = root / 'bin'
            destination.mkdir()
            self.assertEqual(stage_runc(guest, destination), pin)
            self.assertEqual((destination / 'runc-arm64').read_bytes(), binary.read_bytes())
            binary.write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                stage_runc(guest, destination)
            with self.assertRaisesRegex(RuntimeError, 'requires a guest'):
                stage_runc({'identity': {}}, destination)


if __name__ == '__main__':
    unittest.main()
