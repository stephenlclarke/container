"""Runtime benchmark isolation, restoration and acceptance regression checks."""

import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import runtime_benchmark as runtime


class RuntimeTests(unittest.TestCase):
    def test_guest_receipt_rejects_wrong_source_and_tampered_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            revision = 'a' * 40
            (root / 'Package.resolved').write_text(json.dumps({'pins': [
                {'identity': 'containerization', 'state': {'revision': revision}}]}))
            archive = root / 'guest.tar'
            archive.write_bytes(b'qualified guest')
            record = {'schema': 1, 'identity': {'source': revision}, 'archive': str(archive),
                      'archive_sha256': runtime.digest(archive), 'reference': 'example/guest:' + revision}
            receipt = root / 'receipt.json'
            receipt.write_text(json.dumps(record))
            self.assertEqual(runtime.verified_guest(receipt, root), record)
            archive.write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'checksum'):
                runtime.verified_guest(receipt, root)
            record['identity']['source'] = 'b' * 40
            receipt.write_text(json.dumps(record))
            with self.assertRaisesRegex(RuntimeError, 'source'):
                runtime.verified_guest(receipt, root)

    def test_stock_cache_ignores_replaced_fork_pins_but_tracks_effective_inputs(self):
        def pin(identity, revision):
            return {'identity': identity, 'state': {'revision': revision}}

        native = {'version': 3, 'originHash': 'stock-manifest',
                  'pins': [pin('containerization', 'apple'), pin('stock-only', 'one')]}
        fork = {'version': 3, 'originHash': 'fork-manifest-one', 'pins': [pin('containerization', 'fork-one'), pin('extra', 'one')]}
        changed = {'version': 3, 'originHash': 'fork-manifest-two', 'pins': [pin('containerization', 'fork-two'), pin('extra', 'one')]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Tools/bazel').mkdir(parents=True)
            for name in ('MODULE.bazel', 'MODULE.bazel.lock', '.bazelrc', '.bazelversion',
                         'Tools/bazel/dependencies.bzl', 'Tools/bazel/rules.patch', 'Tools/bazel/BUILD.bazel'):
                (root / name).write_text(name)
            overlay = runtime.stock_lockfile(fork, native)
            self.assertEqual(overlay['originHash'], 'stock-manifest')
            self.assertEqual({p['identity'] for p in overlay['pins']}, {'containerization', 'extra', 'stock-only'})
            original = runtime.stock_workspace_key(root, overlay)
            self.assertEqual(original, runtime.stock_workspace_key(root, runtime.stock_lockfile(changed, native)))
            self.assertEqual(fork['pins'][0]['state']['revision'], 'fork-one')
            changed['pins'][1] = pin('extra', 'two')
            self.assertNotEqual(original, runtime.stock_workspace_key(root, runtime.stock_lockfile(changed, native)))
            upgraded = {'pins': [pin('containerization', 'apple-new')]}
            self.assertNotEqual(original, runtime.stock_workspace_key(root, runtime.stock_lockfile(fork, upgraded)))
            for name in ('Tools/bazel/dependencies.bzl', 'Tools/bazel/rules.patch', 'Tools/bazel/BUILD.bazel'):
                (root / name).write_text('changed importer')
                self.assertNotEqual(original, runtime.stock_workspace_key(root, runtime.stock_lockfile(fork, native)))
                (root / name).write_text(name)

    def test_cleanup_accepts_service_that_disappears_during_inspection(self):
        label = runtime.NAMESPACE + '.container-runtime-linux.finished'
        with patch.object(runtime, 'services', side_effect=[[('-', label)], [], []]), \
                patch.object(runtime, 'checked', side_effect=subprocess.CalledProcessError(113, 'launchctl')):
            runtime.stop_owned('fork')

    def test_cleanup_preserves_error_when_service_still_exists(self):
        label = runtime.NAMESPACE + '.apiserver'
        with patch.object(runtime, 'services', return_value=[('-', label)]), \
                patch.object(runtime, 'checked', side_effect=subprocess.CalledProcessError(1, 'launchctl')):
            with self.assertRaises(subprocess.CalledProcessError):
                runtime.stop_owned('fork')

    def test_restage_replaces_readonly_bazel_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source'
            destination = Path(temporary) / 'destination'
            source.write_text('current')
            destination.write_text('old')
            destination.chmod(0o444)
            runtime.copy_replacing(source, destination)
            self.assertEqual(destination.read_text(), 'current')

    def test_refuses_unowned_or_symlinked_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(RuntimeError):
                runtime.own(directory, 'fork')
            target = directory / 'owned'
            runtime.own(target, 'fork')
            runtime.own(target, 'fork')
            with self.assertRaises(RuntimeError):
                runtime.own(target, 'stock')
            link = directory / 'link'
            link.symlink_to(target)
            with self.assertRaises(RuntimeError):
                runtime.own(link, 'fork')

    def test_cleanup_waits_for_asynchronous_unregister(self):
        label = runtime.NAMESPACE + '.apiserver'
        program = runtime.INSTALLS / 'fork/install/bin/container-apiserver'
        with patch.object(runtime, 'services', side_effect=[[('-', label)], [('-', label)], []]), \
                patch.object(runtime, 'checked', side_effect=[f'program = {program}', '']) as command, \
                patch.object(runtime.time, 'sleep') as sleep:
            runtime.stop_owned('fork')
        self.assertEqual(command.call_count, 2)
        sleep.assert_called_once_with(0.1)

    def test_cleanup_refuses_unrelated_binary(self):
        with patch.object(runtime, 'services', return_value=[('-', runtime.NAMESPACE + '.apiserver')]), \
                patch.object(runtime, 'checked', return_value='program = /some/other/binary') as command:
            with self.assertRaises(RuntimeError):
                runtime.stop_owned('fork')
        self.assertEqual(command.call_count, 1)

    def test_active_stock_registration_is_never_stopped(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(runtime, 'services', side_effect=[[('123', 'com.apple.container.apiserver')], []]), \
                patch.object(runtime, 'checked') as command:
            with self.assertRaises(RuntimeError):
                runtime.StockSlot(Path(temporary)).acquire()
            command.assert_not_called()

    def test_inactivity_requires_top_level_state_without_pid(self):
        self.assertTrue(runtime.service_is_inactive('service = {\n\tstate = not running\n\tlast exit code = 1\n}'))
        for description in ['', '\t\tstate = not running',
                            'service = {\n\tstate = spawn scheduled\n}',
                            'service = {\n\tstate = unknown\n}',
                            'service = {\n\tstate = not running\n\tpid = 42\n}']:
            with self.subTest(description=description):
                self.assertFalse(runtime.service_is_inactive(description))

    def test_respawn_gap_is_never_stopped(self):
        label = 'com.apple.container.apiserver'
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(runtime, 'services', side_effect=[[('-', label)], []]), \
                patch.object(runtime, 'checked', return_value='service = {\n\tstate = spawn scheduled\n}') as command:
            with self.assertRaisesRegex(RuntimeError, 'not inactive'):
                runtime.StockSlot(Path(temporary)).acquire()
            self.assertEqual([call.args[0][1] for call in command.call_args_list], ['print'])

    def test_stock_registration_preserved_and_restored(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            plist = evidence / 'original.plist'
            label = 'com.apple.container.apiserver'
            plist.write_bytes(plistlib.dumps({'Label': label}))
            before = plist.read_bytes()
            slot = runtime.StockSlot(evidence)
            description = f'path = {plist}\n\tstate = not running'
            with patch.object(runtime, 'services', side_effect=[[('-', label)], [], [('-', label)], [], []]), \
                    patch.object(runtime, 'checked', side_effect=[description, description, '', '']) as command:
                slot.acquire()
                slot.restore()
            self.assertEqual(plist.read_bytes(), before)
            self.assertTrue(slot.saved[0]['restored'])
            self.assertEqual(command.call_args.args[0][1], 'bootstrap')

    def test_stock_recheck_rejects_changed_state_path_or_contents(self):
        label = 'com.apple.container.apiserver'
        for change in ['state', 'path', 'contents', 'new-registration', 'pid', 'inspection']:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                evidence = Path(temporary)
                plist = evidence / 'original.plist'
                plist.write_bytes(plistlib.dumps({'Label': label}))
                description = f'path = {plist}\n\tstate = not running'
                second = description
                current = [('-', label)]
                if change == 'state':
                    second = description.replace('not running', 'spawn scheduled')
                elif change == 'path':
                    second = description.replace(str(plist), '/changed.plist')
                elif change == 'new-registration':
                    current.append(('-', 'com.apple.container.new'))
                elif change == 'pid':
                    current = [('123', label)]
                def inspect(args, **_kwargs):
                    self.assertEqual(args[1], 'print')
                    if command.call_count == 1:
                        return description
                    if change == 'contents':
                        plist.write_text('changed')
                    if change == 'inspection':
                        raise subprocess.CalledProcessError(1, args)
                    return second
                with patch.object(runtime, 'services', side_effect=[[('-', label)], [], current, []]), \
                        patch.object(runtime, 'checked', side_effect=inspect) as command:
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        runtime.StockSlot(evidence).acquire()
                    self.assertFalse(any(call.args[0][1] == 'bootout' for call in command.call_args_list))

    def test_later_activation_restores_already_unloaded_registration(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            labels = ['com.apple.container.apiserver', 'com.apple.container.images']
            paths = {label: evidence / (label + '.plist') for label in labels}
            for label, path in paths.items():
                path.write_bytes(plistlib.dumps({'Label': label}))
            loaded = set(labels)
            displaced = []
            def inventory(prefix):
                return [('-', label) for label in labels if label in loaded and label.startswith(prefix)]
            def command(args, **_kwargs):
                if args[1] == 'print':
                    label = args[2].rsplit('/', 1)[-1]
                    state = 'spawn scheduled' if displaced and label == labels[1] else 'not running'
                    return f'path = {paths[label]}\n\tstate = {state}'
                if args[1] == 'bootout':
                    label = args[2].rsplit('/', 1)[-1]
                    loaded.remove(label)
                    displaced.append(label)
                elif args[1] == 'bootstrap':
                    loaded.add(plistlib.loads(Path(args[3]).read_bytes())['Label'])
                else:
                    self.fail('Unexpected operation ' + args[1])
                return ''
            slot = runtime.StockSlot(evidence)
            with patch.object(runtime, 'services', side_effect=inventory), \
                    patch.object(runtime, 'checked', side_effect=command):
                try:
                    with self.assertRaisesRegex(RuntimeError, 'no longer inactive'):
                        slot.acquire()
                finally:
                    slot.restore()
            self.assertEqual(displaced, [labels[0]])
            self.assertEqual(loaded, set(labels))
            self.assertTrue(all(row['restored'] for row in slot.saved))

    def test_stock_restore_reconciles_bootout_before_receipt_update(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            plist = evidence / 'original.plist'
            plist.write_text('original')
            label = 'com.apple.container.apiserver'
            slot = runtime.StockSlot(evidence)
            slot.saved = [dict(label=label, path=str(plist), sha256=runtime.digest(plist), unloaded=False)]
            with patch.object(runtime, 'services', return_value=[]), patch.object(runtime, 'checked') as command:
                slot.restore()
            self.assertEqual(command.call_args.args[0][1], 'bootstrap')
            with patch.object(runtime, 'services', return_value=[('-', label)]), \
                    patch.object(runtime, 'checked', return_value=f'path = {plist}') as command:
                slot.restore()
            self.assertEqual(command.call_args.args[0][1], 'print')
            with patch.object(runtime, 'services', return_value=[('-', label)]), \
                    patch.object(runtime, 'checked', return_value='path = /unrelated'):
                with self.assertRaisesRegex(RuntimeError, 'was replaced'):
                    slot.restore()

    def test_cleanup_preserves_loaded_original_while_stopping_private_stock(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist = Path(temporary) / 'original.plist'
            plist.write_text('original')
            label = 'com.apple.container.apiserver'
            private = 'com.apple.container.container-runtime-linux.owned'
            original = dict(label=label, path=str(plist), sha256=runtime.digest(plist), restored=False)
            program = runtime.INSTALLS / 'stock/install/libexec/container-runtime-linux'
            with patch.object(runtime, 'services', side_effect=[[('-', label), ('42', private)], [('-', label)]]), \
                    patch.object(runtime, 'checked', side_effect=[
                        f'path = {plist}\nprogram = /original/bin', f'program = {program}', '']) as command:
                runtime.stop_owned('stock', originals=[original])
            bootouts = [call.args[0] for call in command.call_args_list if call.args[0][1] == 'bootout']
            self.assertEqual(bootouts, [['launchctl', 'bootout', f'gui/{runtime.os.getuid()}/{private}']])

    def test_missing_workloads_fail_acceptance_and_junit(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner = runtime.RuntimeRunner(evidence, evidence)
            with self.assertRaises(RuntimeError):
                runtime.finish(runner, 3, [])
            self.assertFalse(json.loads((evidence / 'acceptance.json').read_text())['passed'])
            self.assertEqual(len(list(ET.parse(evidence / 'timings.xml').iter('failure'))), 16)

    def test_complete_workloads_include_setup_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner = runtime.RuntimeRunner(evidence, evidence)
            for lane in ['stock', 'fork']:
                for fixture in runtime.FIXTURES:
                    runner.rows.append(dict(component='runtime-stack', lane=lane, fixture=fixture,
                                            trial=1, seconds=1, status=0, log='example.log'))
            runtime.finish(runner, 1, [])
            self.assertTrue(json.loads((evidence / 'acceptance.json').read_text())['passed'])
            with self.assertRaises(RuntimeError):
                runtime.finish(runner, 1, ['stock cleanup failed'])
            self.assertFalse(json.loads((evidence / 'acceptance.json').read_text())['passed'])

    def test_build_environment_matches_normal_launcher(self):
        with patch.dict(runtime.os.environ, {'PATH': '/unrelated', 'TMP': '/different'}):
            env = runtime.build_environment()
        self.assertEqual(env['PATH'], '/usr/bin:/bin:/usr/sbin:/sbin')
        self.assertEqual(env['TMP'], env['TMPDIR'])
        self.assertEqual(env['TEMP'], env['TMPDIR'])


if __name__ == '__main__':
    unittest.main()
