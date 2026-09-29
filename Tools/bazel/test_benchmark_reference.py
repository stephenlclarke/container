"""Offline admission tests for the pinned historical runtime measurements."""

import copy
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import benchmark_reference as reference
import runtime_benchmark as runtime


def historical_fixture(trials=7):
    rows = [
        {'component': 'runtime-stack', 'lane': 'stock', 'fixture': fixture,
         'trial': trial, 'seconds': trial / 10, 'status': 0, 'log': 'original.log'}
        for fixture in runtime.FIXTURES for trial in range(1, trials + 1)
    ]
    return {
        'source': reference.SOURCE,
        'historical': True,
        'identityLimit': 'historical signed binary differs from measured private binary',
        'protocol': {'runtimeTrials': trials},
        'runtime': {'raw': rows},
        'runtimeLaneFingerprints': {'stock': {
            'workload_image': runtime.ALPINE,
            'kernel_sha256': runtime.KERNEL_SHA,
        }},
        'phaseHosts': {'runtimeBenchmark': {
            'model': 'Mac-test', 'memoryBytes': 32_000_000_000,
            'macOSVersion': '26.0', 'macOSBuild': 'A123', 'architecture': 'arm64',
            'powerSource': 'AC',
        }},
    }


class HistoricalReferenceTests(unittest.TestCase):
    def test_pinned_archive_is_required_even_for_offline_cache_reuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'reference.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('benchmark.json', json.dumps(historical_fixture()))
                archive.writestr('manifest.json', '{}')
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            with patch.object(reference, 'ARCHIVE_SHA256', sha), \
                    patch.object(reference.subprocess, 'run') as download:
                self.assertEqual(reference.fetch(path)['source'], reference.SOURCE)
                download.assert_not_called()
                path.write_bytes(path.read_bytes() + b'tampered')
                with self.assertRaisesRegex(RuntimeError, 'published digest'):
                    reference.fetch(path)
                download.assert_not_called()

    def test_all_56_stock_samples_are_imported_without_changing_raw_values(self):
        document = historical_fixture()
        original = copy.deepcopy(document['runtime']['raw'])
        rows = reference.runtime_samples(document, runtime.FIXTURES, 7)
        self.assertEqual(len(rows), 56)
        self.assertEqual(document['runtime']['raw'], original)
        for row, raw in zip(rows, original):
            for field in ('component', 'lane', 'fixture', 'trial', 'seconds', 'status'):
                self.assertEqual(row[field], raw[field])
            self.assertTrue(row['historical'])
            self.assertEqual(row['reference_archive_sha256'], reference.ARCHIVE_SHA256)

    def test_missing_duplicate_failed_or_invalid_historical_trials_fail_closed(self):
        for change in ('trial-count', 'missing', 'duplicate', 'failed', 'nan', 'zero', 'workload'):
            with self.subTest(change=change):
                document = historical_fixture()
                rows = document['runtime']['raw']
                if change == 'trial-count':
                    document['protocol']['runtimeTrials'] = 6
                elif change == 'missing':
                    rows.pop()
                elif change == 'duplicate':
                    rows[0]['trial'] = 2
                elif change == 'failed':
                    rows[0]['status'] = 1
                elif change == 'nan':
                    rows[0]['seconds'] = float('nan')
                elif change == 'zero':
                    rows[0]['seconds'] = 0
                else:
                    rows[0]['fixture'] = 'different-workload'
                with self.assertRaises(RuntimeError):
                    reference.runtime_samples(document, runtime.FIXTURES, 7)

    def test_setup_workload_command_and_runner_contract_drift_fail_closed(self):
        here = Path(runtime.__file__)
        source = here.read_text()
        runner = here.with_name('fork_benchmark.py').read_text()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root / here.name
            shared = root / 'fork_benchmark.py'
            local.write_text(source)
            shared.write_text(runner)
            reference.validate_contract(local, reference.RUNTIME_CONTRACTS)
            reference.validate_contract(shared, reference.RUNNER_CONTRACT)
            for original, changed in (
                ("'runtime-ready'", "'different-ready'"),
                ("'--disable-kernel-install'", "'--enable-kernel-install'"),
                ("self.run('runtime-stack'", "self.run('changed-stack'"),
            ):
                self.assertIn(original, source)
                local.write_text(source.replace(original, changed, 1))
                with self.assertRaisesRegex(RuntimeError, 'Runtime workload differs'):
                    reference.validate_contract(local, reference.RUNTIME_CONTRACTS)
            local.write_text(source)
            self.assertIn('stdin=subprocess.DEVNULL', runner)
            shared.write_text(runner.replace('stdin=subprocess.DEVNULL',
                                             'stdin=subprocess.PIPE', 1))
            with self.assertRaisesRegex(RuntimeError, 'Runner.run'):
                reference.validate_contract(shared, reference.RUNNER_CONTRACT)

    def test_runtime_image_kernel_and_host_drift_fail_closed(self):
        document = historical_fixture()
        source = Path(runtime.__file__)
        host = document['phaseHosts']['runtimeBenchmark']
        responses = {
            ('sysctl', '-n', 'hw.model'): host['model'],
            ('sysctl', '-n', 'hw.memsize'): str(host['memoryBytes']),
            ('sw_vers', '-productVersion'): host['macOSVersion'],
            ('sw_vers', '-buildVersion'): host['macOSBuild'],
            ('uname', '-m'): host['architecture'],
            ('pmset', '-g', 'batt'): "Now drawing from 'AC Power'\n",
        }

        def observed(command, **_):
            return responses[tuple(command)]

        with patch.object(reference.subprocess, 'check_output', side_effect=observed):
            reference.validate_runtime(document, source, runtime.ALPINE,
                                       {'kernel_sha256': runtime.KERNEL_SHA})
            with self.assertRaisesRegex(RuntimeError, 'image or kernel'):
                reference.validate_runtime(document, source, 'different-image',
                                           {'kernel_sha256': runtime.KERNEL_SHA})
            with self.assertRaisesRegex(RuntimeError, 'image or kernel'):
                reference.validate_runtime(document, source, runtime.ALPINE,
                                           {'kernel_sha256': 'different-kernel'})
            responses[('sysctl', '-n', 'hw.model')] = 'Different host'
            with self.assertRaisesRegex(RuntimeError, 'host differs: model'):
                reference.validate_runtime(document, source, runtime.ALPINE,
                                           {'kernel_sha256': runtime.KERNEL_SHA})
            responses[('sysctl', '-n', 'hw.model')] = host['model']
            responses[('pmset', '-g', 'batt')] = "Now drawing from 'Battery Power'\n"
            with self.assertRaisesRegex(RuntimeError, 'host differs: power source'):
                reference.validate_runtime(document, source, runtime.ALPINE,
                                           {'kernel_sha256': runtime.KERNEL_SHA})
            responses[('pmset', '-g', 'batt')] = "Now drawing from 'AC Power'\n"
            document['phaseHosts']['runtimeBenchmark']['powerSource'] = 'Battery'
            with self.assertRaisesRegex(RuntimeError, 'host differs: power source'):
                reference.validate_runtime(document, source, runtime.ALPINE,
                                           {'kernel_sha256': runtime.KERNEL_SHA})

    def test_candidate_only_preparation_never_builds_or_stages_stock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / 'source'
            (workspace / 'Sources').mkdir(parents=True)
            (workspace / 'Sources' / 'fixture.swift').write_text('source')
            (workspace / 'Package.resolved').write_text('{"pins": []}')
            enrollment = root / 'Library/Application Support/ContainerFamily/retained/workflow'
            enrollment.mkdir(parents=True)
            (enrollment / 'ssd-volume.uuid').write_text('test-volume')
            bazel = root / 'bazel'
            bazel.write_bytes(b'pinned bazel')
            evidence = root / 'evidence'
            evidence.mkdir()
            (evidence / 'guest-artifact.json').write_text('{}')
            (evidence / 'builder-artifact.json').write_text('{}')
            disk = plistlib.dumps({'VolumeUUID': 'test-volume',
                                   'MountPoint': '/Volumes/SSD', 'Internal': False},
                                  fmt=plistlib.FMT_XML).decode()

            def command(arguments, **_):
                if arguments[:2] == ['/usr/sbin/diskutil', 'info']:
                    return disk
                if arguments[:2] == ['security', 'find-identity']:
                    return runtime.IDENTITY
                if arguments[:3] == ['git', 'rev-parse', 'HEAD']:
                    return reference.SOURCE
                self.fail('Unexpected stock preparation command: ' + str(arguments))

            with patch.object(Path, 'home', return_value=root), \
                    patch.object(runtime, 'ROOT', workspace), \
                    patch.object(runtime, 'STORAGE', root / 'storage'), \
                    patch.object(runtime, 'BAZEL', bazel), \
                    patch.object(runtime, 'BAZEL_SHA', runtime.digest(bazel)), \
                    patch.object(runtime, 'INSTALLS', root / 'installs'), \
                    patch.object(runtime, 'checked', side_effect=command), \
                    patch.object(runtime, 'prepare_assets'), \
                    patch.object(runtime, 'build_inputs', return_value={}), \
                    patch.object(runtime, 'build_environment', return_value={}), \
                    patch.object(runtime, 'stage') as stage, \
                    patch.object(runtime.subprocess, 'run') as build:
                runtime.prepare_all(evidence, candidate_only=True)
            stage.assert_called_once()
            self.assertEqual(stage.call_args.args[0], 'fork')
            build.assert_called_once()
            self.assertIn('//:container', build.call_args.args[0])
            self.assertNotIn('//:component', build.call_args.args[0])
            recorded = json.loads((evidence / 'source-inputs.json').read_text())
            self.assertIsNone(recorded['stock'])
            self.assertIsNone(recorded['stock_native_pins'])
            self.assertEqual(set(recorded['source_sha256']), {'fork'})

    def test_candidate_only_executes_all_eight_fixture_commands(self):
        class Recorder:
            def __init__(self):
                self.calls = []

            def command(self, lane, fixture, trial, arguments, *args, **kwargs):
                self.calls.append((lane, fixture, trial, arguments, args, kwargs))

        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(runtime, 'STATE', Path(temporary)), \
                patch.object(runtime, 'start_lane'):
            (Path(temporary) / 'fork').mkdir()
            runner = Recorder()
            runtime.run_lane(runner, 'fork', 2)
        measured = [(lane, fixture, trial) for lane, fixture, trial, _, _, _ in runner.calls
                    if fixture in runtime.FIXTURES]
        self.assertEqual(len(measured), 16)
        self.assertEqual({fixture for _, fixture, _ in measured}, set(runtime.FIXTURES))
        self.assertEqual({lane for lane, _, _ in measured}, {'fork'})
        self.assertEqual({trial for _, _, trial in measured}, {1, 2})

    def test_historical_comparison_never_acquires_or_runs_stock(self):
        document = historical_fixture()

        class Recorder:
            def __init__(self, evidence, _scratch):
                self.evidence = evidence
                self.rows = []

        def candidate(runner, lane, trials):
            self.assertEqual((lane, trials), ('fork', 7))
            runner.rows.extend({'component': 'runtime-stack', 'lane': lane,
                                'fixture': fixture, 'trial': trial,
                                'seconds': 1, 'status': 0, 'log': 'candidate.log'}
                               for fixture in runtime.FIXTURES for trial in range(1, trials + 1))

        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(runtime, 'RuntimeRunner', Recorder), \
                patch.object(runtime, 'run_lane', side_effect=candidate) as run_lane, \
                patch.object(runtime, 'stop_owned') as stop, \
                patch.object(runtime, 'checked', return_value='host'), \
                patch.object(runtime, 'finish') as finish, \
                patch.object(runtime.StockSlot, 'acquire', side_effect=AssertionError('stock acquired')), \
                patch.object(runtime.StockSlot, 'restore', side_effect=AssertionError('stock restored')), \
                patch.object(reference, 'validate_runtime'), \
                patch.object(runtime.os, 'getloadavg', return_value=(0, 0, 0)):
            evidence = Path(temporary)
            (evidence / 'fork-fingerprint.json').write_text('{}')
            runtime.benchmark(evidence, 7, reference=document)
            retained = json.loads((evidence / 'historical-reference.json').read_text())
            self.assertEqual(retained['archiveSHA256'], reference.ARCHIVE_SHA256)
            self.assertFalse(retained['referenceRebuilt'])
            self.assertFalse(retained['referenceRerun'])
        run_lane.assert_called_once()
        self.assertEqual(stop.call_args_list[0].args, ('fork',))
        self.assertEqual(finish.call_args.kwargs, {'candidate_only': False, 'historical': True})
        rows = finish.call_args.args[0].rows
        self.assertEqual(len([row for row in rows if row['lane'] == 'stock']), 56)
        self.assertEqual(len([row for row in rows if row['lane'] == 'fork']), 56)

    def test_candidate_only_benchmark_never_acquires_or_runs_stock(self):
        class Recorder:
            def __init__(self, evidence, _scratch):
                self.evidence = evidence
                self.rows = []

        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(runtime, 'RuntimeRunner', Recorder), \
                patch.object(runtime, 'run_lane') as run_lane, \
                patch.object(runtime, 'stop_owned') as stop, \
                patch.object(runtime, 'checked', return_value='host'), \
                patch.object(runtime, 'finish') as finish, \
                patch.object(runtime.StockSlot, 'acquire', side_effect=AssertionError('stock acquired')), \
                patch.object(runtime.StockSlot, 'restore', side_effect=AssertionError('stock restored')), \
                patch.object(runtime.os, 'getloadavg', return_value=(0, 0, 0)):
            runtime.benchmark(Path(temporary), 7, candidate_only=True)
        run_lane.assert_called_once()
        self.assertEqual(run_lane.call_args.args[1:], ('fork', 7))
        self.assertEqual(stop.call_args_list[0].args, ('fork',))
        self.assertEqual(finish.call_args.kwargs, {'candidate_only': True, 'historical': False})


if __name__ == '__main__':
    unittest.main()
