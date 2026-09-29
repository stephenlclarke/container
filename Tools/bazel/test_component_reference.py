"""Historical lanes never dispatch builds or become fresh passing assertions."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import component_reference as reference
import comparison_review
import fork_benchmark as benchmark


def sample_reference():
    pairs = benchmark.PAIRS
    raw = []
    for component, pair in pairs.items():
        for lane in ('stock', 'fork'):
            fixtures = {'prepare-build': 1, 'component-recompile': 1}
            if component == 'container-builder-shim':
                fixtures.update({'toolchain': 1, 'prepare-linux-build': 1, 'cached-linux-build': 3,
                                 'prefetch-tests': 3, **{name: 3 for name in GO_NAMES}})
            else:
                fixtures.update({'cleanup-bazel': 1, 'cached-build': 3, **{name: 3 for name in pair['tests']}})
            if component == 'container':
                fixtures.update({'cli-run-help': 11, 'cli-version': 11})
            if component == 'swift-nio-ssl':
                fixtures.update({'prepare-tls': 1, 'tls-repeated_handshakes': 3, 'tls-many_writes_512b': 3})
            failed = 'ContainerResourceTests' if component == 'container' else 'NIOSSLTests' if component == 'swift-nio-ssl' else None
            if failed and lane == 'fork':
                fixtures[failed] = 1
            for fixture, count in fixtures.items():
                for trial in range(count):
                    raw.append(dict(component=component, lane=lane, fixture=fixture, trial=trial,
                                    seconds=1.0, status=3 if fixture == failed and lane == 'fork' else 0))
    return {'identityLimit': 'Historical measured private binary differs from signed release.',
            'componentInputs': {name: {lane: {'revision': pair[lane]} for lane in ('stock', 'fork')}
                                for name, pair in pairs.items()},
            'componentToolchain': {'thirdPartyLockSHA256': hashlib.sha256(b'lock').hexdigest(),
                                   'bazelSHA256': benchmark.BAZEL_SHA, 'swiftVersion': 'Swift version', 'swiftTarget': 'Target'},
            'phaseHosts': {'runtimeBenchmark': dict(model='M', memoryBytes=1, macOSVersion='27', macOSBuild='A', architecture='arm64', powerSource='AC')},
            'components': {'raw': raw, 'knownCompatibilityDifferences': [r for r in raw if r['status']],
                           'goRaw': [dict(lane=lane, fixture=name, trial=trial, iterations=1024, ns_per_op=1.0)
                                     for lane in ('stock', 'fork') for name in GO_NAMES for trial in range(3)],
                           'goMatrix': [{'fixture': name} for name in GO_NAMES]}}


GO_NAMES = ('BenchmarkDirectReaderAt', 'BenchmarkDirectReaderAtRandom',
            'BenchmarkPrefetcherSequential', 'BenchmarkPrefetcherRandom')


class ComponentReferenceTests(unittest.TestCase):
    def test_reference_rows_keep_raw_values_and_known_failures_separate(self):
        data = sample_reference()
        self.assertEqual(len(data['components']['raw']), 236)
        rows, differences = reference.retained_rows(data, ['container'])
        self.assertEqual(len(rows), 186)
        self.assertTrue(all(r['lane'] == 'stock' for r in rows if r['component'] == 'container'))
        self.assertTrue(all(r['historical'] for r in rows))
        self.assertEqual([r['component'] for r in differences], ['swift-nio-ssl'])
        self.assertEqual(len(reference.retained_go(data)), 24)
        for mutation in ('missing', 'duplicate', 'timeout', 'nan'):
            broken = copy.deepcopy(data)
            raw = broken['components']['raw']
            if mutation == 'missing': raw.pop()
            if mutation == 'duplicate': raw[-1] = raw[0]
            if mutation == 'timeout': raw[0]['status'] = 124
            if mutation == 'nan': raw[0]['seconds'] = float('nan')
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                reference.retained_rows(broken, ['container'])
        data['components']['goRaw'][0]['iterations'] = 1
        with self.assertRaises(RuntimeError): reference.retained_go(data)

    def test_dependency_recipe_pin_compiler_and_host_drift_reject_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'Tools/bazel').mkdir(parents=True)
            (root / 'Package.resolved').write_bytes(b'lock')
            source = Path(benchmark.__file__).read_text()
            (root / 'Tools/bazel/fork_benchmark.py').write_text(source)
            for name in reference.RECIPE_FILES:
                (root / name).write_text(name)
            data = sample_reference()
            pairs = copy.deepcopy(benchmark.PAIRS)
            pairs['container']['fork'] = 'new-candidate'
            originals = {name: (root / name).read_bytes() for name in reference.RECIPE_FILES}
            originals['Tools/bazel/fork_benchmark.py'] = source.encode()
            def command(args, unused):
                if args[0] == 'git': return ''
                if args[0] == 'xcrun': return 'Swift version Target'
                if args[0] == 'pmset': return "Now drawing from 'AC Power'"
                return {'hw.model': 'M', 'hw.memsize': '1', '-productVersion': '27',
                        '-buildVersion': 'A', '-m': 'arm64'}[args[-1]]
            with patch.object(reference, 'command', side_effect=command), \
                    patch.object(reference, 'original', side_effect=lambda unused, name: originals[name]):
                self.assertEqual(reference.validate_inputs(data, pairs, root, benchmark.BAZEL_SHA), ['container'])
                for kind in ('dependency', 'stock', 'compiler', 'host', 'recipe', 'workload', 'patch'):
                    current = copy.deepcopy(pairs)
                    record = copy.deepcopy(data)
                    if kind == 'dependency': current['swift-nio-ssl']['fork'] = 'changed'
                    if kind == 'stock': current['container']['stock'] = 'changed'
                    if kind == 'compiler': record['componentToolchain']['swiftVersion'] = 'new Swift'
                    if kind == 'host': record['phaseHosts']['runtimeBenchmark']['model'] = 'Other'
                    if kind == 'recipe': (root / '.bazelrc').write_text('changed')
                    if kind == 'workload': (root / 'Tools/bazel/fork_benchmark.py').write_text(source.replace('range(11)', 'range(10)'))
                    if kind == 'patch': (root / 'Tools/bazel/new.patch').write_text('changed')
                    with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                        reference.validate_inputs(record, current, root, benchmark.BAZEL_SHA)
                    (root / '.bazelrc').write_text('.bazelrc')
                    (root / 'Tools/bazel/fork_benchmark.py').write_text(source)
                    (root / 'Tools/bazel/new.patch').unlink(missing_ok=True)

    def test_historical_rows_in_runtime_runner_are_not_fresh_junit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            runner = benchmark.Runner(root, root)
            for lane, seconds in [('stock', 1), ('fork', 2)]:
                for trial in range(3):
                    runner.rows.append(dict(component='runtime-stack', lane=lane, fixture='same', trial=trial,
                                            seconds=seconds, status=0, historical=lane == 'stock', log='sample'))
            runner.rows[-1]['seconds'] = 10
            runner.report()
            cases = list(ET.parse(root / 'timings.xml').iter('testcase'))
            self.assertFalse(any(c.get('name').startswith('stock/') for c in cases))
            matrix = json.loads((root / 'matrix.json').read_text())[0]
            self.assertEqual(matrix['comparison'], 'historical')
            self.assertEqual(matrix['historical_lanes'], ['stock'])
            self.assertEqual(matrix['worst_trial_ratio'], 10)
            self.assertFalse(matrix['passed'])

    def test_candidate_inventory_cannot_pass_from_historical_dependencies_only(self):
        data = sample_reference()
        rows = [dict(r, status=0) for r in data['components']['raw'] if r['component'] == 'container' and r['lane'] == 'stock']
        for row in rows: row['lane'] = 'fork'
        reference.require_candidate_rows(rows, ['container'], benchmark.PAIRS)
        for selected in ([], rows[:-1], [dict(r, trial=0) for r in rows]):
            with self.assertRaises(RuntimeError): reference.require_candidate_rows(selected, ['container'], benchmark.PAIRS)

    def test_main_dispatches_only_current_container_and_retains_historical_differences(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            evidence, scratch = root / 'evidence', root / 'scratch'
            calls = []
            data = sample_reference()
            class FakeRunner(benchmark.Runner):
                def run(self, component, lane, fixture, trial, args, cwd, timeout=600):
                    calls.append((component, lane, fixture))
                    row = dict(component=component, lane=lane, fixture=fixture, trial=trial, seconds=1, status=0, log='fresh')
                    self.rows.append(row)
                    return row
                def cli(self, lane):
                    for fixture in ('cli-run-help', 'cli-version'):
                        for trial in range(11): self.run('container', lane, fixture, trial, [], root)
                def builder(self): raise AssertionError('Old builder executed')
                def tls(self): raise AssertionError('Old SSL executed')
            def prepare(component, lane, base):
                calls.append((component, lane, 'prepare'))
                target = base / component / lane
                (target / 'workspace/Sources').mkdir(parents=True)
                (target / 'inputs.json').write_text('{}')
            with patch.object(benchmark, 'Runner', FakeRunner), patch.object(benchmark, 'prepare', side_effect=prepare), \
                    patch.object(benchmark, 'STORAGE', root), patch.object(benchmark, 'digest', return_value=benchmark.BAZEL_SHA), \
                    patch.object(benchmark, 'output', return_value='candidate'), patch.object(benchmark.subprocess, 'run'), \
                    patch.object(benchmark, 'install_signal_handlers'), patch.object(benchmark, 'PAIRS', copy.deepcopy(benchmark.PAIRS)), \
                    patch('benchmark_reference.fetch', return_value=data), patch('benchmark_reference.retain'), \
                    patch.object(reference, 'validate_inputs', return_value=['container']), \
                    patch('sys.argv', ['benchmark', '--reuse-reference', '--evidence', str(evidence), '--scratch', str(scratch)]):
                with self.assertRaises(SystemExit) as result:
                    benchmark.main()
                self.assertEqual(result.exception.code, 2)  # Historical SSL difference remains visible.
            self.assertTrue(calls)
            self.assertEqual({(c, lane) for c, lane, _ in calls}, {('container', 'fork')})
            report = json.loads((evidence / 'comparison-review.json').read_text())
            self.assertTrue(report['completed'])
            self.assertEqual(report['expected_differences'], [])
            self.assertEqual(len(report['historical_expected_differences']), 1)
            self.assertEqual([row['component'] for row in report['superseded_historical_differences']], ['container'])
            self.assertFalse(any('stock/' in case.get('name', '') for case in ET.parse(evidence / 'timings.xml').iter('testcase')))
            (evidence / 'historical-differences.json').write_text('[]')
            with patch('benchmark_reference.fetch', return_value=data), self.assertRaises(RuntimeError):
                comparison_review.review(evidence)


if __name__ == '__main__':
    unittest.main()
