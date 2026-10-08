"""Historical lanes never dispatch builds or become fresh passing assertions."""

import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import component_reference as reference
import benchmark_reference
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
    def test_all_candidate_flag_requires_reference_reuse(self):
        with patch('sys.argv', ['benchmark', '--measure-all-candidates',
                                '--evidence', '/tmp/evidence', '--scratch', '/tmp/scratch']):
            with self.assertRaises(SystemExit) as result:
                benchmark.main()
        self.assertEqual(result.exception.code, 2)

    def test_only_exact_cancellation_revision_preserves_component_workload_identity(self):
        source = Path(benchmark.__file__).read_text()
        previous = source
        for current, old in (
            (', stop_grace: int = 10', ''),
            ('def stop_group(grace: int):', 'def stop_group():'),
            ('time.monotonic() + grace', 'time.monotonic() + 10'),
            ('stop_group(10)', 'stop_group()'),
            ('except BaseException as error:\n                        watchdog.cancel()\n'
             '                        watchdog.join()\n'
             '                        stop_group(stop_grace if isinstance(error, (KeyboardInterrupt, SystemExit)) and not expired.is_set() else 10)',
             'except BaseException:\n                        stop_group()'),
        ):
            self.assertEqual(previous.count(current), 1)
            previous = previous.replace(current, old, 1)
        self.assertEqual(reference.units(previous), reference.units(source))
        for before, after in (
            ('time.monotonic_ns() - start', 'time.monotonic_ns() - start + 1'),
            ('time.monotonic() + grace', 'time.monotonic() + grace + 1'),
            ('for trial in range(11):', 'for trial in range(10):'),
        ):
            with self.subTest(change=before):
                self.assertIn(before, source)
                self.assertNotEqual(reference.units(previous), reference.units(source.replace(before, after, 1)))

    def test_reference_rows_keep_raw_values_and_known_failures_separate(self):
        data = sample_reference()
        self.assertEqual(len(data['components']['raw']), 236)
        rows, differences = reference.retained_rows(data, ['container'])
        self.assertEqual(len(rows), 186)
        self.assertTrue(all(r['lane'] == 'stock' for r in rows if r['component'] == 'container'))
        self.assertTrue(all(r['historical'] for r in rows))
        self.assertEqual([r['component'] for r in differences], ['swift-nio-ssl'])
        two_changed, two_differences = reference.retained_rows(data, ['containerization', 'container'])
        self.assertEqual(len(two_changed), 168)
        self.assertTrue(all(r['lane'] == 'stock' for r in two_changed
                            if r['component'] in {'containerization', 'container'}))
        self.assertEqual(two_differences, differences)
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
            (root / 'Tools/bazel/artifacts').mkdir(parents=True)
            repo_root = Path(benchmark.__file__).resolve().parents[2]
            source = Path(benchmark.__file__).read_text()
            (root / 'Tools/bazel/fork_benchmark.py').write_text(source)
            for name in (reference.recipe_compatibility.IMPORTER,
                         reference.recipe_compatibility.CONSUMER,
                         'Tools/bazel/artifacts/recipe_compatibility.py'):
                destination = root / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(repo_root / name, destination)
            patch_name = reference.recipe_compatibility.HOST_FIXTURE
            patch_path = root / patch_name
            shutil.copyfile(repo_root / patch_name, patch_path)
            historical_patch = subprocess.check_output(
                ['git', 'show', benchmark_reference.SOURCE + ':' + patch_name], cwd=repo_root)
            for name in reference.RECIPE_FILES:
                (root / name).write_text(name)
            data = sample_reference()
            pairs = copy.deepcopy(benchmark.PAIRS)
            pairs['container']['fork'] = 'new-candidate'
            old_lock = {'version': 3, 'originHash': 'authenticated-origin', 'pins': [
                {'identity': 'containerization', 'kind': 'remoteSourceControl',
                 'location': 'https://github.com/stephenlclarke/containerization',
                 'state': {'revision': pairs['containerization']['fork']}},
                {'identity': 'other', 'kind': 'remoteSourceControl', 'location': 'https://example.org/other',
                 'state': {'revision': 'unchanged'}}]}
            old_bytes = (json.dumps(old_lock, indent=2) + '\n').encode()
            data['componentToolchain']['thirdPartyLockSHA256'] = hashlib.sha256(old_bytes).hexdigest()
            (root / 'Package.resolved').write_bytes(old_bytes)
            originals = {name: (root / name).read_bytes() for name in reference.RECIPE_FILES}
            originals['Tools/bazel/fork_benchmark.py'] = subprocess.check_output(
                ['git', 'show', benchmark_reference.SOURCE + ':Tools/bazel/fork_benchmark.py'], cwd=repo_root)
            originals[patch_name] = historical_patch
            originals['Package.resolved'] = old_bytes
            def command(args, unused):
                if args[0] == 'git': return patch_name + '\n'
                if args[0] == 'xcrun': return 'Swift version Target'
                if args[0] == 'pmset': return "Now drawing from 'AC Power'"
                return {'hw.model': 'M', 'hw.memsize': '1', '-productVersion': '27',
                        '-buildVersion': 'A', '-m': 'arm64'}[args[-1]]
            admission = {}
            with patch.object(reference, 'command', side_effect=command), \
                    patch.object(reference, 'original', side_effect=lambda unused, name: originals[name]):
                self.assertEqual(reference.validate_inputs(data, pairs, root, benchmark.BAZEL_SHA, admission), ['container'])
                recipe_admission = admission['recipe_admission']
                self.assertEqual(recipe_admission['mode'], 'known-consumer-verifier-update+known-host-timeout-fixture-update')
                self.assertIn(patch_name, recipe_admission['changedFiles'])
                self.assertNotEqual(recipe_admission['producerRecipeSHA256'],
                                    recipe_admission['currentRecipeSHA256'])
                policy_path = repo_root / 'Tools/bazel/artifacts/recipe_compatibility.py'
                self.assertEqual(recipe_admission['policySHA256'],
                                 reference.recipe_compatibility.digest(policy_path.read_bytes()))
                self.assertNotEqual(admission['workload_admission']['producerSHA256'],
                                    admission['workload_admission']['currentSHA256'])
                next_pairs = copy.deepcopy(pairs)
                next_pairs['containerization']['fork'] = 'a' * 40
                new_lock = copy.deepcopy(old_lock)
                new_lock['pins'][0]['state']['revision'] = 'a' * 40
                new_bytes = (json.dumps(new_lock, indent=2) + '\n').encode()
                (root / 'Package.resolved').write_bytes(new_bytes)
                self.assertEqual(reference.validate_inputs(data, next_pairs, root, benchmark.BAZEL_SHA),
                                 ['containerization', 'container'])
                for mutation in ('unrelated_pin', 'location', 'version', 'duplicate', 'missing', 'wrong_selected', 'old_digest'):
                    record = copy.deepcopy(data)
                    changed_lock = copy.deepcopy(new_lock)
                    selected_pairs = copy.deepcopy(next_pairs)
                    if mutation == 'unrelated_pin': changed_lock['pins'][1]['state']['revision'] = 'changed'
                    if mutation == 'location': changed_lock['pins'][0]['location'] += '/changed'
                    if mutation == 'version': changed_lock['version'] = 4
                    if mutation == 'duplicate': changed_lock['pins'].append(copy.deepcopy(changed_lock['pins'][0]))
                    if mutation == 'missing': changed_lock['pins'].pop(0)
                    if mutation == 'wrong_selected': selected_pairs['containerization']['fork'] = 'b' * 40
                    if mutation == 'old_digest': record['componentToolchain']['thirdPartyLockSHA256'] = '0' * 64
                    (root / 'Package.resolved').write_text(json.dumps(changed_lock, indent=2) + '\n')
                    with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                        reference.validate_inputs(record, selected_pairs, root, benchmark.BAZEL_SHA)
                (root / 'Package.resolved').write_bytes(old_bytes)
                for kind in ('dependency', 'stock', 'compiler', 'host', 'recipe',
                             'workload', 'workload_order', 'unknown_workload_transition',
                             'unknown_tls_transition', 'unknown_patch_transition',
                             'unknown_native_recipe_transition', 'patch'):
                    current = copy.deepcopy(pairs)
                    record = copy.deepcopy(data)
                    if kind == 'dependency': current['swift-nio-ssl']['fork'] = 'changed'
                    if kind == 'stock': current['container']['stock'] = 'changed'
                    if kind == 'compiler': record['componentToolchain']['swiftVersion'] = 'new Swift'
                    if kind == 'host': record['phaseHosts']['runtimeBenchmark']['model'] = 'Other'
                    if kind == 'recipe': (root / '.bazelrc').write_text('changed')
                    if kind == 'workload': (root / 'Tools/bazel/fork_benchmark.py').write_text(source.replace('range(11)', 'range(10)'))
                    if kind == 'workload_order':
                        before = "[('cli-run-help', ['run', '--help']), ('cli-version', ['--version'])]"
                        after = "[('cli-version', ['--version']), ('cli-run-help', ['run', '--help'])]"
                        self.assertIn(before, source)
                        (root / 'Tools/bazel/fork_benchmark.py').write_text(source.replace(before, after))
                    if kind == 'unknown_workload_transition':
                        before = 'trial_lanes = lanes if trial % 2 == 0 else list(reversed(lanes))'
                        after = 'trial_lanes = list(lanes) if trial % 2 == 0 else list(reversed(lanes))'
                        self.assertIn(before, source)
                        (root / 'Tools/bazel/fork_benchmark.py').write_text(source.replace(before, after))
                    if kind == 'unknown_tls_transition':
                        before = "for lane in lanes:\n            workspace = self.scratch / component / lane / 'workspace'"
                        after = "for lane in reversed(lanes):\n            workspace = self.scratch / component / lane / 'workspace'"
                        self.assertIn(before, source)
                        (root / 'Tools/bazel/fork_benchmark.py').write_text(source.replace(before, after, 1))
                    if kind == 'unknown_patch_transition':
                        patch_path.write_bytes(patch_path.read_bytes() + b'\n# unreviewed change\n')
                    if kind == 'unknown_native_recipe_transition':
                        native_path = root / reference.recipe_compatibility.IMPORTER
                        native_path.write_bytes(native_path.read_bytes() + b'\n# unreviewed change\n')
                    if kind == 'patch': (root / 'Tools/bazel/new.patch').write_text('changed')
                    with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                        reference.validate_inputs(record, current, root, benchmark.BAZEL_SHA)
                    (root / '.bazelrc').write_text('.bazelrc')
                    (root / 'Tools/bazel/fork_benchmark.py').write_text(source)
                    shutil.copyfile(repo_root / patch_name, patch_path)
                    shutil.copyfile(repo_root / reference.recipe_compatibility.IMPORTER,
                                    root / reference.recipe_compatibility.IMPORTER)
                    shutil.copyfile(repo_root / reference.recipe_compatibility.CONSUMER,
                                    root / reference.recipe_compatibility.CONSUMER)
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
        containerization = [dict(r, status=0, lane='fork') for r in data['components']['raw']
                            if r['component'] == 'containerization' and r['lane'] == 'stock']
        self.assertEqual(len(containerization), 18)
        reference.require_candidate_rows(containerization, ['containerization'], benchmark.PAIRS)
        for selected in ([], containerization[:-1], containerization + [containerization[0]],
                         containerization + [dict(containerization[0], fixture='cli-run-help')]):
            with self.assertRaises(RuntimeError):
                reference.require_candidate_rows(selected, ['containerization'], benchmark.PAIRS)

    def test_main_dispatches_only_two_changed_forks_and_retains_historical_differences(self):
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
                    patch.object(reference, 'validate_inputs', return_value=['containerization', 'container']), \
                    patch('sys.argv', ['benchmark', '--reuse-reference', '--evidence', str(evidence), '--scratch', str(scratch)]):
                with self.assertRaises(SystemExit) as result:
                    benchmark.main()
                self.assertEqual(result.exception.code, 2)  # Historical SSL difference remains visible.
            self.assertTrue(calls)
            self.assertEqual({(c, lane) for c, lane, _ in calls},
                             {('containerization', 'fork'), ('container', 'fork')})
            report = json.loads((evidence / 'comparison-review.json').read_text())
            self.assertTrue(report['completed'])
            self.assertEqual(report['expected_differences'], [])
            self.assertEqual(len(report['historical_expected_differences']), 1)
            self.assertEqual([row['component'] for row in report['superseded_historical_differences']], ['container'])
            self.assertFalse(any('stock/' in case.get('name', '') for case in ET.parse(evidence / 'timings.xml').iter('testcase')))
            (evidence / 'historical-differences.json').write_text('[]')
            with patch('benchmark_reference.fetch', return_value=data), self.assertRaises(RuntimeError):
                comparison_review.review(evidence)

    def test_all_candidate_mode_prepares_only_forks_and_keeps_all_stock_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            evidence, scratch = root / 'evidence', root / 'scratch'
            calls = []
            data = sample_reference()

            class FakeRunner(benchmark.Runner):
                def run(self, component, lane, fixture, trial, args, cwd, timeout=600):
                    calls.append((component, lane, fixture))
                    row = dict(component=component, lane=lane, fixture=fixture, trial=trial,
                               seconds=1, status=0, log='fresh')
                    self.rows.append(row)
                    return row

                def bazel(self, component, lane, fixture, trial, command, targets, extra=()):
                    return self.run(component, lane, fixture, trial, [], root)

                def cli(self, lane):
                    for fixture in ('cli-run-help', 'cli-version'):
                        for trial in range(11):
                            self.run('container', lane, fixture, trial, [], root)

                def builder(self, lanes=('stock', 'fork')):
                    self.run('container-builder-shim', 'fork', 'toolchain', 0, [], root)
                    for fixture in ('prepare-build', 'prepare-linux-build', 'component-recompile'):
                        self.run('container-builder-shim', 'fork', fixture, 0, [], root)
                    for trial in range(3):
                        for fixture in ('cached-linux-build', 'prefetch-tests',
                                        'BenchmarkDirectReaderAt', 'BenchmarkDirectReaderAtRandom',
                                        'BenchmarkPrefetcherSequential', 'BenchmarkPrefetcherRandom'):
                            self.run('container-builder-shim', 'fork', fixture, trial, [], root)
                    go_path = evidence / 'go-benchmarks.json'
                    retained = json.loads(go_path.read_text())
                    retained += [dict(lane='fork', fixture=name, trial=trial, iterations=1024,
                                      ns_per_op=1.0)
                                 for name in GO_NAMES for trial in range(3)]
                    go_path.write_text(json.dumps(retained))

                def tls(self, lanes=('stock', 'fork')):
                    self.run('swift-nio-ssl', 'fork', 'prepare-tls', 0, [], root)
                    for trial in range(3):
                        for fixture in ('tls-repeated_handshakes', 'tls-many_writes_512b'):
                            self.run('swift-nio-ssl', 'fork', fixture, trial, [], root)

            def prepare(component, lane, base):
                calls.append((component, lane, 'prepare'))
                target = base / component / lane
                (target / 'workspace/Sources').mkdir(parents=True)
                (target / 'inputs.json').write_text('{}')
                return target / 'workspace'

            def validate_reference(_reference, _pairs, _root, _bazel_sha, admission=None):
                if admission is not None:
                    admission.update(recipe_admission={'producerRecipeSHA256': 'old',
                                                       'currentRecipeSHA256': 'new', 'policySHA256': 'policy'},
                                     workload_admission={'producerSHA256': 'old',
                                                         'currentSHA256': 'new', 'policySHA256': 'workload-policy'})
                return ['containerization', 'container']

            with patch.object(benchmark, 'Runner', FakeRunner), patch.object(benchmark, 'prepare', side_effect=prepare), \
                    patch.object(benchmark, 'STORAGE', root), patch.object(benchmark, 'digest', return_value=benchmark.BAZEL_SHA), \
                    patch.object(benchmark, 'output', return_value='candidate'), patch.object(benchmark.subprocess, 'run'), \
                    patch.object(benchmark, 'install_signal_handlers'), patch.object(benchmark, 'PAIRS', copy.deepcopy(benchmark.PAIRS)), \
                    patch('benchmark_reference.fetch', return_value=data), patch('benchmark_reference.retain'), \
                    patch.object(reference, 'validate_inputs', side_effect=validate_reference), \
                    patch('sys.argv', ['benchmark', '--reuse-reference', '--measure-all-candidates',
                                       '--evidence', str(evidence), '--scratch', str(scratch)]):
                benchmark.main()

            metadata = json.loads((evidence / 'metadata.json').read_text())
            all_components = list(benchmark.PAIRS)
            self.assertEqual(metadata['measured_components'], all_components)
            self.assertEqual(metadata['candidate_measurement_scope'], 'all')
            self.assertEqual(metadata['component_reference_admission']['recipe_admission']['policySHA256'], 'policy')
            self.assertEqual(metadata['component_reference_admission']['workload_admission']['policySHA256'],
                             'workload-policy')
            self.assertEqual({(component, lane) for component, lane, _ in calls},
                             {(component, 'fork') for component in all_components})
            historical = json.loads((evidence / 'historical-results.json').read_text())
            self.assertEqual({(row['component'], row['lane']) for row in historical},
                             {(component, 'stock') for component in all_components})
            self.assertTrue(all(row['historical'] for row in historical))
            self.assertFalse(any(row['lane'] == 'stock' for row in json.loads((evidence / 'results.json').read_text())))
            self.assertTrue(json.loads((evidence / 'comparison-review.json').read_text())['completed'])


if __name__ == '__main__':
    unittest.main()
