"""Runtime benchmark isolation, restoration and acceptance regression checks."""

import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import runtime_benchmark as runtime


class RuntimeTests(unittest.TestCase):
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

    def test_stock_registration_preserved_and_restored(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            plist = evidence / 'original.plist'
            label = 'com.apple.container.apiserver'
            plist.write_bytes(plistlib.dumps({'Label': label}))
            before = plist.read_bytes()
            slot = runtime.StockSlot(evidence)
            with patch.object(runtime, 'services', side_effect=[[('-', label)], []]), \
                    patch.object(runtime, 'checked', side_effect=[f'path = {plist}', '', '']) as command:
                slot.acquire()
                slot.restore()
            self.assertEqual(plist.read_bytes(), before)
            self.assertTrue(slot.saved[0]['restored'])
            self.assertEqual(command.call_args.args[0][1], 'bootstrap')

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
