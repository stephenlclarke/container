"""A failed gate blocks dependent publication work while independent evidence continues."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import qualification
import benchmark_reference
import docker_benchmark
from test_docker_benchmark import sample_reference
from docker_benchmark import historical_samples


class QualificationTests(unittest.TestCase):
    def test_full_run_imports_published_lower_layers(self):
        with patch.object(qualification, 'checkpoint', return_value='a' * 40):
            stages = {name: command for name, _, command, _ in qualification.stages(Path('/evidence'), 7)}
        for name, kind in (('guest', 'guest'), ('guest-runc', 'guest-runc'), ('builder', 'builder')):
            self.assertIn('published_lower.py', ' '.join(map(str, stages[name])))
            self.assertIn('--kind', stages[name])
            self.assertIn(kind, stages[name])
            self.assertNotIn('guest_artifact.py', ' '.join(map(str, stages[name])))
            self.assertNotIn('builder_artifact.py', ' '.join(map(str, stages[name])))

    def test_comparison_revalidates_pinned_rows_and_recomputes_apple_ratio(self):
        for mutation in (None, 'docker', 'apple', 'matrix'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                runtime, docker = evidence / 'runtime-benchmark', evidence / 'docker-benchmark'
                runtime.mkdir()
                docker.mkdir()
                reference = sample_reference()
                reference['protocol']['runtimeTrials'] = 7
                reference['runtime'] = {'raw': [dict(component='runtime-stack', lane='stock', fixture=name,
                                                     trial=trial, seconds=1, status=0)
                                               for name in qualification.FIXTURES for trial in range(1, 8)]}
                apple = benchmark_reference.runtime_samples(reference, qualification.FIXTURES, 7)
                current = [dict(row, lane='fork', seconds=2, historical=False) for row in apple]
                docker_rows, medians = historical_samples(reference, 'colima', 7)
                if mutation == 'docker': docker_rows[0]['seconds'] = 100
                if mutation == 'apple': apple[0]['seconds'] = 100
                (runtime / 'results.json').write_text(json.dumps(apple + current))
                (runtime / 'matrix.json').write_text(json.dumps([
                    dict(fixture=name, stock=1, fork=2, ratio=0.1 if mutation == 'matrix' else 2,
                         passed=True, historical_lanes=['stock']) for name in qualification.FIXTURES]))
                (docker / 'results.json').write_text(json.dumps(docker_rows))
                (docker / 'acceptance.json').write_text(json.dumps(dict(passed=True, historical=True, medians=medians)))
                with patch.object(benchmark_reference, 'fetch', return_value=reference):
                    if mutation in ('docker', 'apple'):
                        with self.assertRaises(RuntimeError):
                            qualification.benchmark_summary(evidence, verify_reference=True)
                        self.assertFalse((evidence / 'runtime-comparison-acceptance.json').exists())
                    else:
                        self.assertEqual(qualification.benchmark_summary(evidence, verify_reference=True), mutation is None)
                        receipt = json.loads((evidence / 'runtime-comparison-acceptance.json').read_text())
                        self.assertTrue(receipt['reference_verified'])
                        qualification.benchmark_summary(evidence)
                        self.assertEqual(json.loads((evidence / 'runtime-comparison-acceptance.json').read_text()), receipt)

    def test_hosted_outer_timeout_allows_bounded_api_calls_and_report_exit(self):
        with patch.object(qualification, 'checkpoint', return_value='a' * 40):
            stages = qualification.stages(Path('/evidence'), 7)
        stage = next(row for row in stages if row[0] == 'github-quality')
        self.assertEqual(stage[3], qualification.DEFAULT_WAIT_SECONDS + 180)
        self.assertEqual(stage[3], 5580)

    def test_release_workflow_never_dispatches_historical_lanes(self):
        with patch.object(qualification, 'checkpoint', return_value='a' * 40):
            stages = {name: (dependencies, command) for name, dependencies, command, _ in qualification.stages(Path('/evidence'), 7)}
        self.assertEqual(next(iter(stages)), 'benchmark-reference')
        self.assertEqual(stages['tools'][0], ['benchmark-reference'])
        self.assertIn('--reference-admission', stages['benchmark-reference'][1])
        self.assertIn('--reuse-reference', stages['docker-benchmark'][1])
        self.assertIn('--candidate-only', stages['runtime-smoke'][1])
        for name in ('runtime-benchmark', 'component-benchmarks', 'docker-benchmark'):
            self.assertIn('--reuse-reference', stages[name][1])
        self.assertEqual(stages['runtime-comparison'][0], ['runtime-benchmark', 'docker-benchmark'])
        self.assertIn('runtime-comparison', stages['release'][0])

    def test_reference_only_diagnostic_cannot_be_admitted_as_full_qualification(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            with patch.object(qualification, 'checkpoint', return_value='a' * 40), \
                    patch.object(benchmark_reference, 'fetch', return_value={'identityLimit': 'historical'}), \
                    patch.object(benchmark_reference, 'retain') as retained, \
                    patch.object(docker_benchmark, 'reuse') as admitted:
                qualification.reference_admission(evidence, 7)
            retained.assert_called_once()
            admitted.assert_called_once_with(evidence / 'docker-reference-admission', 'colima', 7)
            record = json.loads((evidence / 'qualification.json').read_text())
            self.assertEqual(record['kind'], 'reference-only-diagnostic')
            self.assertFalse(record['passed'])
            self.assertTrue(record['referenceAdmissionPassed'])
            with self.assertRaisesRegex(RuntimeError, 'previous failures'):
                qualification.run(evidence, 7)

    def test_reference_failure_blocks_builds_without_overwriting_active_full_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            source = 'a' * 40
            active = {'source': source, 'passed': False, 'stages': [
                {'name': 'benchmark-reference', 'state': 'running'}], 'failures': []}
            (evidence / 'qualification.json').write_text(json.dumps(active))
            with patch.object(qualification, 'checkpoint', return_value=source), \
                    patch.object(benchmark_reference, 'fetch', side_effect=RuntimeError('reference unavailable')), \
                    patch.object(docker_benchmark, 'reuse') as admitted:
                with self.assertRaisesRegex(RuntimeError, 'reference unavailable'):
                    qualification.reference_admission(evidence, 7)
            admitted.assert_not_called()
            self.assertEqual(json.loads((evidence / 'qualification.json').read_text()), active)

            # The real stage dependency graph prevents a failed first admission
            # from dispatching any compile, guest, builder, or runtime stage.
            calls = []
            def execute(_component, _lane, fixture, *_arguments):
                calls.append(fixture)
                return {'status': int(fixture == 'benchmark-reference'),
                        'log': fixture + '.log', 'seconds': 1}
            (evidence / 'qualification.json').unlink()
            with patch.object(qualification, 'checkpoint', return_value=source), \
                    patch.object(qualification.Runner, 'run', side_effect=execute):
                with self.assertRaises(SystemExit):
                    qualification.run(evidence, 7)
            self.assertEqual(calls, ['benchmark-reference'])
            report = json.loads((evidence / 'qualification.json').read_text())
            self.assertEqual(next(row['state'] for row in report['stages'] if row['name'] == 'tools'), 'blocked')
            self.assertEqual(next(row['state'] for row in report['stages'] if row['name'] == 'docker-benchmark'), 'blocked')
            self.assertEqual(next(row['state'] for row in report['stages'] if row['name'] == 'github-quality'), 'blocked')

    def test_docker_timing_gate_rejects_missing_timeout_and_tenfold_samples(self):
        for fault in (None, 'tenfold', 'missing', 'timeout', 'failed-reference', 'nan', 'historical-candidate'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                candidate = evidence / 'runtime-benchmark'
                docker = evidence / 'docker-benchmark'
                candidate.mkdir()
                docker.mkdir()
                raw = [dict(fixture=name, lane='fork', trial=trial, seconds=2, status=0)
                       for name in qualification.FIXTURES for trial in range(1, 8)]
                if fault == 'tenfold': raw[0]['seconds'] = 10
                if fault == 'missing': raw.pop()
                if fault == 'timeout': raw[0]['status'] = 124
                if fault == 'nan': raw[0]['seconds'] = float('nan')
                if fault == 'historical-candidate': raw[0]['historical'] = True
                (candidate / 'results.json').write_text(json.dumps(raw))
                (candidate / 'matrix.json').write_text(json.dumps([
                    dict(fixture=name, stock=1, fork=2, ratio=2, passed=True, historical_lanes=['stock'])
                    for name in qualification.FIXTURES]))
                (docker / 'results.json').write_text(json.dumps([
                    dict(fixture=name, lane='docker', trial=trial, seconds=1, status=0, historical=True)
                    for name in qualification.FIXTURES for trial in range(1, 8)]))
                (docker / 'acceptance.json').write_text(json.dumps(dict(
                    passed=fault != 'failed-reference', historical=True,
                    medians={name: 1 for name in qualification.FIXTURES})))
                self.assertEqual(qualification.benchmark_summary(evidence), fault is None)
                result = json.loads((evidence / 'runtime-comparison-acceptance.json').read_text())
                self.assertEqual(result['passed'], fault is None)
                self.assertIn('not contemporaneous', (evidence / 'BENCHMARK.md').read_text())

    def test_local_release_requires_hosted_quality_without_rerunning_scanners(self):
        for failed in ('integration', 'github-quality', None):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                commands = {}

                def execute(component, lane, fixture, trial, command, cwd, timeout):
                    commands[fixture] = command
                    return {'status': int(fixture == failed), 'log': fixture + '.log', 'seconds': 1}

                with patch.object(qualification, 'checkpoint', return_value='a' * 40), \
                        patch.object(qualification.Runner, 'run', side_effect=execute):
                    if failed:
                        with self.assertRaises(SystemExit):
                            qualification.run(evidence, 1)
                    else:
                        qualification.run(evidence, 1)
                report = json.loads((evidence / 'qualification.json').read_text())
                release = next(row for row in report['stages'] if row['name'] == 'release')
                self.assertNotIn('codeql', commands)
                self.assertNotIn('quality', commands)
                self.assertIn('github-quality', commands)
                if failed:
                    self.assertNotIn('release', commands)
                    self.assertIn(failed, release['blocked_by'])
                else:
                    self.assertEqual(release['state'], 'passed')

    def test_failed_integration_blocks_component_benchmarks_without_changing_successful_workload(self):
        for integration_status in (0, 1):
            with self.subTest(integration_status=integration_status), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                dispatched = []

                def execute(_component, _lane, fixture, *_arguments):
                    dispatched.append(fixture)
                    return {'status': integration_status if fixture == 'integration' else 0,
                            'log': fixture + '.log', 'seconds': 1}

                with patch.object(qualification, 'checkpoint', return_value='a' * 40), \
                        patch.object(qualification.Runner, 'run', side_effect=execute):
                    if integration_status:
                        with self.assertRaises(SystemExit):
                            qualification.run(evidence, 1)
                    else:
                        qualification.run(evidence, 1)
                report = json.loads((evidence / 'qualification.json').read_text())
                self.assertEqual(len(report['stages']), 25)
                component = next(row for row in report['stages'] if row['name'] == 'component-benchmarks')
                if integration_status:
                    self.assertEqual(component['state'], 'blocked')
                    self.assertEqual(component['blocked_by'], ['integration'])
                    self.assertNotIn('component-benchmarks', dispatched)
                    self.assertFalse(report['passed'])
                else:
                    self.assertEqual(component['state'], 'passed')
                    self.assertIn('component-benchmarks', dispatched)

    def test_failed_gate_is_retained_and_blocks_only_its_dependents(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            stages = [('quality', [], ['false'], 1), ('release', ['quality'], ['must-not-run'], 1),
                      ('independent', [], ['true'], 1)]
            rows = [{'status': 1, 'log': 'quality.log', 'seconds': 1},
                    {'status': 0, 'log': 'independent.log', 'seconds': 2}]
            with patch.object(qualification, 'stages', return_value=stages), \
                    patch.object(qualification, 'checkpoint', return_value='a' * 40), \
                    patch.object(qualification.Runner, 'run', side_effect=rows) as command:
                with self.assertRaises(SystemExit):
                    qualification.run(evidence, 1)
            report = json.loads((evidence / 'qualification.json').read_text())
            self.assertFalse(report['passed'])
            self.assertEqual([row['state'] for row in report['stages']], ['failed', 'blocked', 'passed'])
            self.assertEqual(report['stages'][1]['blocked_by'], ['quality'])
            self.assertEqual(command.call_count, 2)

    def test_existing_failure_evidence_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            receipt = evidence / 'qualification.json'
            receipt.write_text('{"passed": false}')
            with self.assertRaisesRegex(RuntimeError, 'previous failures'):
                qualification.run(evidence, 1)
            self.assertEqual(receipt.read_text(), '{"passed": false}')


if __name__ == '__main__':
    unittest.main()
