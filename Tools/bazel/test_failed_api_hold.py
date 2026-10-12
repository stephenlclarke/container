"""A diagnosed installation can be held only by an explicit, unchanged identity."""

import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import failed_api_hold as hold
import runtime_benchmark
from runtime_benchmark import StockSlot


class FailedAPIHoldTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / 'app'
        self.plist = self.app / 'apiserver/apiserver.plist'
        self.plist.parent.mkdir(parents=True)
        self.binary = self.root / 'container-apiserver'
        self.binary.write_bytes(b'approved binary')
        self.plist.write_bytes(plistlib.dumps({'Label': hold.LABEL,
            'ProgramArguments': [str(self.binary), 'start'],
            'EnvironmentVariables': {'CONTAINER_APP_ROOT': str(self.app)}}))
        directory = self.app / 'containers/saved'
        directory.mkdir(parents=True)
        self.record = directory / 'lifecycle-v2.json'
        self.record.write_text(json.dumps({'snapshot': dict(running=False, restarting=False,
            paused=False, pid=0, removalInProgress=False)}))
        self.approval = dict(program=str(self.binary), binary_sha256=hold.digest(self.binary),
                             plist_sha256=hold.digest(self.plist))
        self.description = '\n'.join('\t' + name + ' = ' + value for name, value in {
            'path': str(self.plist), 'program': str(self.binary), 'state': 'spawn scheduled',
            'active count': '0', 'last exit code': '1'}.items()) + '\n'
        self.loaded = True
        self.commands = []
        self.slot = StockSlot(self.root)
        for name, value in [('APP', self.app), ('PLIST', self.plist)]:
            patcher = patch.object(hold, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.checked = patch.object(hold, 'checked', side_effect=self.command).start()
        self.services = patch.object(hold, 'services', side_effect=lambda prefix: [('-', hold.LABEL)]
                                     if self.loaded and prefix == 'com.apple.container.' else []).start()
        self.processes = patch.object(hold, 'processes', return_value={}).start()
        self.addCleanup(patch.stopall)

    def command(self, arguments, **kwargs):
        self.commands.append(arguments)
        if arguments[1] == 'print':
            return self.description
        self.assertEqual(arguments[1], 'bootout')
        # A crash or cancellation here must already be recoverable.
        self.assertEqual(json.loads((self.root / 'service-restoration.json').read_text()), self.slot.saved)
        self.loaded = False
        return ''

    def test_records_stop_before_mutation_and_uses_standard_restore_shape(self):
        hold.hold_failed_api(self.slot, self.approval)
        row, = self.slot.saved
        self.assertEqual(row['path'], str(self.plist))
        self.assertEqual(row['sha256'], hold.digest(self.plist))
        self.assertTrue(row['unloaded'])
        self.assertTrue(row['explicitly_stopped_failed_api'])
        report = json.loads((self.root / 'failed-api-hold.json').read_text())
        self.assertFalse(report['inventory_confirmed'])
        self.assertEqual(self.record.read_text(), json.dumps({'snapshot': dict(running=False,
            restarting=False, paused=False, pid=0, removalInProgress=False)}))

    def test_hold_composes_with_real_slot_acquisition_and_restoration(self):
        helper = 'com.apple.container.container-core-images'
        helper_plist = self.root / 'helper.plist'
        helper_plist.write_bytes(plistlib.dumps({'Label': helper}))
        descriptions = {hold.LABEL: self.description,
                        helper: f'\tpath = {helper_plist}\n\tstate = not running\n'}
        loaded = set(descriptions)
        mutations = []

        def services(prefix):
            return [('-', label) for label in sorted(loaded) if label.startswith(prefix)]

        def command(arguments, **kwargs):
            if arguments[1] == 'print':
                return descriptions[arguments[2].split('/', 2)[2]]
            if arguments[1] == 'bootout':
                label = arguments[2].split('/', 2)[2]
                self.assertIn(label, loaded, 'An already held API must not be stopped twice')
                self.assertEqual(json.loads((self.root / 'service-restoration.json').read_text()), self.slot.saved)
                loaded.remove(label)
                mutations.append(('stop', label))
            else:
                self.assertEqual(arguments[1], 'bootstrap')
                label = plistlib.loads(Path(arguments[3]).read_bytes())['Label']
                loaded.add(label)
                mutations.append(('restore', label))
            return ''

        with patch.object(hold, 'checked', side_effect=command), \
                patch.object(hold, 'services', side_effect=services), \
                patch.object(runtime_benchmark, 'checked', side_effect=command), \
                patch.object(runtime_benchmark, 'services', side_effect=services):
            hold.hold_failed_api(self.slot, self.approval)
            self.slot.acquire()
            self.assertFalse(loaded)
            self.slot.restore()
        self.assertEqual(loaded, set(descriptions))
        self.assertEqual(mutations, [('stop', hold.LABEL), ('stop', helper),
                                    ('restore', hold.LABEL), ('restore', helper)])
        self.assertTrue(all(row['restored'] for row in self.slot.saved))

    def test_rejects_changed_binary_or_plist(self):
        for key in ('binary_sha256', 'plist_sha256'):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                hold.hold_failed_api(self.slot, dict(self.approval, **{key: '0' * 64}))
        self.assertFalse(self.slot.saved)
        self.assertFalse(any(command[1] == 'bootout' for command in self.commands))

    def test_rejects_invalid_or_different_binding(self):
        for value in (None, {}, {**self.approval, 'extra': True},
                      {**self.approval, 'binary_sha256': False}):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                hold.inspect_failed_api(value)
        data = plistlib.loads(self.plist.read_bytes())
        data['EnvironmentVariables']['CONTAINER_APP_ROOT'] = '/other'
        self.plist.write_bytes(plistlib.dumps(data))
        self.approval['plist_sha256'] = hold.digest(self.plist)
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            hold.inspect_failed_api(self.approval)

    def test_rejects_running_or_unrecognised_services(self):
        for rows in ([('9', hold.LABEL)], [('-', hold.LABEL), ('-', 'com.apple.container.unknown')], []):
            self.services.side_effect = lambda prefix: rows if prefix == 'com.apple.container.' else []
            with self.subTest(rows=rows), self.assertRaises(RuntimeError):
                hold.hold_failed_api(self.slot, self.approval)
        self.assertFalse(self.slot.saved)

    def test_rejects_changed_failure_state_or_executing_api(self):
        original = self.description
        for description in (original.replace('spawn scheduled', 'not running'),
                            original.replace('last exit code = 1', 'last exit code = 0'),
                            original + '\tpid = 42\n'):
            self.description = description
            with self.subTest(description=description), self.assertRaises(RuntimeError):
                hold.hold_failed_api(self.slot, self.approval)

    def test_rejects_other_active_helper(self):
        self.services.side_effect = lambda prefix: [('-', hold.LABEL), ('-', 'com.apple.container.machine-apiserver')] if prefix == 'com.apple.container.' else []
        with self.assertRaisesRegex(RuntimeError, 'Another original'):
            hold.hold_failed_api(self.slot, self.approval)

    def test_rejects_live_guests_controllers_or_clients(self):
        for name in ('container', 'container-apiserver', 'container-runtime-linux', 'machine-apiserver',
                     'devcontainer-engine', 'com.apple.Virtualization.VirtualMachine'):
            self.processes.return_value = {42: {'program': '/test/' + name}}
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, 'runtime process'):
                hold.hold_failed_api(self.slot, self.approval)

    def test_rejects_active_missing_or_changed_workload_records(self):
        self.record.write_text('{"snapshot":{"running":true}}')
        with self.assertRaisesRegex(RuntimeError, 'not stopped'):
            hold.hold_failed_api(self.slot, self.approval)
        self.record.unlink()
        with self.assertRaises(FileNotFoundError):
            hold.hold_failed_api(self.slot, self.approval)
        with patch.object(hold, 'inspect_failed_api', side_effect=[('', {'one': 'a'}), ('', {'one': 'b'})]):
            with self.assertRaisesRegex(RuntimeError, 'records changed'):
                hold.hold_failed_api(self.slot, self.approval)
        self.assertFalse(self.slot.saved)

    def test_bootout_failure_preserves_restore_intent(self):
        def command(arguments, **kwargs):
            if arguments[1] == 'print':
                return self.description
            raise RuntimeError('bootout interrupted')
        self.checked.side_effect = command
        with self.assertRaisesRegex(RuntimeError, 'interrupted'):
            hold.hold_failed_api(self.slot, self.approval)
        self.assertEqual(len(json.loads((self.root / 'service-restoration.json').read_text())), 1)

    def test_surviving_registration_is_a_failure(self):
        self.checked.side_effect = lambda *args, **kwargs: self.description
        with self.assertRaisesRegex(RuntimeError, 'survived'):
            hold.hold_failed_api(self.slot, self.approval)
        self.assertTrue(self.slot.saved)

    def test_surviving_process_preserves_recovery_despite_absent_registration(self):
        self.processes.side_effect = [{}, {}, {42: {'program': str(self.binary)}}]
        def bounded_wait(probe, seconds):
            self.assertEqual(seconds, 5)
            self.assertFalse(probe())
            raise RuntimeError('Process survived stop deadline')
        with patch.object(hold, 'wait_for', side_effect=bounded_wait):
            with self.assertRaisesRegex(RuntimeError, 'survived stop deadline'):
                hold.hold_failed_api(self.slot, self.approval)
        self.assertFalse(self.loaded)
        self.assertTrue(self.slot.saved)

    def test_changed_records_after_stop_preserve_recovery(self):
        def command(arguments, **kwargs):
            result = self.command(arguments, **kwargs)
            if arguments[1] == 'bootout':
                self.record.write_text(self.record.read_text() + '\n')
            return result
        self.checked.side_effect = command
        with self.assertRaisesRegex(RuntimeError, 'records changed during'):
            hold.hold_failed_api(self.slot, self.approval)
        self.assertFalse(self.loaded)
        self.assertTrue(self.slot.saved)


if __name__ == '__main__':
    unittest.main()
