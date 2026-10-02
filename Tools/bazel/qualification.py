#!/usr/bin/env python3
"""Run the reduced release gates in dependency order and retain every stage outcome."""

import argparse
import json
import math
import statistics
from pathlib import Path
import sys

from fork_benchmark import ROOT, STORAGE, Runner, install_signal_handlers
from quality import checkpoint
from github_quality import DEFAULT_WAIT_SECONDS
from runtime_benchmark import FIXTURES


def stages(evidence: Path, trials: int) -> list[tuple]:
    """Compiler and service checks finish before timing and release submission."""
    def script(name: str, *arguments) -> list[str]:
        return [sys.executable, str(ROOT / 'Tools/bazel' / (name + '.py')), *map(str, arguments)]

    make = ['make', 'QUALIFICATION_EVIDENCE=' + str(evidence)]
    prepared = evidence / 'runtime-smoke'
    component_scratch = STORAGE / 'qualification-components' / checkpoint()
    component_args = ['--use-prepared'] if component_scratch.exists() else []
    return [
        ('benchmark-reference', [], script('qualification', '--reference-admission', '--trials', trials,
                                           '--evidence', evidence), 600),
        ('tools', ['benchmark-reference'], make + ['bazel-tools-test'], 300),
        ('dependencies', ['tools'], make + ['bazel-dependency-test'], 1800),
        ('container', ['dependencies'], make + ['bazel-build', 'bazel-test', 'bazel-repository-test'], 1800),
        ('maintenance', ['container'], script('maintenance', '--evidence', evidence / 'maintenance'), 900),
        ('documentation', ['container'], script('documentation', '--evidence', evidence / 'documentation'), 1800),
        ('host', ['container'], ['env', '-u', 'CI', str(ROOT / 'Tools/bazel/run.sh'), 'test', '//:engine-core-host-tests',
                               '//:engine-session-host-tests', '//:engine-service-host-tests',
                               '//:container-api-host-tests', '//:containerization-os-host-tests',
                               '//:containerization-oci-host-tests', '--test_env=CI',
                               '--test_env=CONTAINER_HOST_TESTS=1', '--strategy=TestRunner=local',
                               '--nocache_test_results', '--test_timeout=120'], 900),
        ('guest', ['dependencies'], script('published_lower', '--kind', 'guest', '--evidence', evidence / 'guest'), 1800),
        ('guest-runc', ['guest'], script('published_lower', '--kind', 'guest-runc', '--evidence', evidence / 'guest-runc'), 1800),
        ('linux', ['guest'], script('linux_tests', '--evidence', evidence / 'linux'), 1800),
        ('builder', ['tools'], script('published_lower', '--kind', 'builder', '--evidence', evidence / 'builder'), 1800),
        ('services', ['tools'], script('service_artifacts', '--evidence', evidence / 'services'), 1800),
        ('service-integration', ['container', 'services'], script('service_integration', '--evidence', evidence / 'service-integration'), 900),
        ('runtime-smoke', ['container', 'guest', 'linux', 'builder'], script('runtime_benchmark', '--candidate-only', '--prepare', '--trials', 1,
                    '--guest-artifact', evidence / 'guest/guest-artifact.json',
                    '--builder-artifact', evidence / 'builder/builder-artifact.json', '--evidence', prepared), 3600),
        ('vm-integration', ['runtime-smoke', 'guest-runc'], script('vm_integration', '--guest-artifact', evidence / 'guest-runc/guest-artifact.json',
                    '--evidence', evidence / 'vm-integration'), 3600),
        ('integration', ['vm-integration'], script('runtime_integration', '--prepared', prepared, '--evidence', evidence / 'integration', '--coverage'), 9000),
        ('coverage', ['container'], script('coverage', '--evidence', evidence / 'coverage'), 1800),
        ('combined-coverage', ['coverage', 'integration'], script('combined_coverage', '--unit', evidence / 'coverage',
                    '--integration', evidence / 'integration/coverage', '--evidence', evidence / 'combined-coverage'), 600),
        ('component-benchmarks', ['dependencies', 'container', 'builder', 'integration'], script('fork_benchmark',
                    '--reuse-reference', '--evidence', evidence / 'components', '--scratch', component_scratch, *component_args), 10800),
        ('runtime-benchmark', ['integration'], script('runtime_benchmark', '--reuse-reference', '--prepared', prepared,
                    '--trials', trials, '--evidence', evidence / 'runtime-benchmark'), 1800),
        ('docker-benchmark', ['runtime-smoke'], script('docker_benchmark', '--reuse-reference', '--context', 'colima',
                    '--trials', trials, '--evidence', evidence / 'docker-benchmark'), 1800),
        ('runtime-comparison', ['runtime-benchmark', 'docker-benchmark'], script('qualification',
                    '--compare-only', '--trials', trials, '--evidence', evidence), 60),
        # Four bounded 30-second context/poll/job calls plus 60 seconds for process/report exit.
        ('github-quality', ['benchmark-reference'], script('github_quality', '--evidence', evidence / 'github-quality'), DEFAULT_WAIT_SECONDS + 180),
        ('release', ['maintenance', 'documentation', 'host', 'services', 'service-integration', 'integration', 'combined-coverage', 'github-quality', 'runtime-comparison'], script('release_artifact',
                    '--prepared', prepared, '--service-artifacts', evidence / 'services/service-artifacts.json',
                    '--notarize', '--evidence', evidence / 'release'), 3600),
        ('install', ['release'], script('release_install', '--release', evidence / 'release', '--evidence', evidence / 'install'), 900),
    ]


def benchmark_summary(evidence: Path, trials: int = 7, *, verify_reference: bool = False) -> bool:
    runtime_path = evidence / 'runtime-benchmark/matrix.json'
    docker_path = evidence / 'docker-benchmark/acceptance.json'
    runtime = json.loads(runtime_path.read_text()) if runtime_path.exists() else []
    docker = json.loads(docker_path.read_text()) if docker_path.exists() else {}
    server_transition = docker.get('serverVersionTransition', {})
    if docker.get('passed') and docker.get('historical'):
        from docker_benchmark import HISTORICAL_DOCKER_SERVER_VERSION, ADMITTED_DOCKER_SERVER_VERSION
        if (server_transition.get('historical') != HISTORICAL_DOCKER_SERVER_VERSION
                or server_transition.get('current') not in {
                    HISTORICAL_DOCKER_SERVER_VERSION, ADMITTED_DOCKER_SERVER_VERSION}):
            raise RuntimeError('Historical Docker server-version provenance is missing or unsupported')
    def samples(name: str) -> list[dict]:
        path = evidence / name / 'results.json'
        return json.loads(path.read_text()) if path.exists() else []

    candidate_raw, docker_raw = samples('runtime-benchmark'), samples('docker-benchmark')
    if verify_reference:
        from benchmark_reference import fetch, runtime_samples
        from docker_benchmark import historical_samples
        reference = fetch()
        expected_docker, expected_medians = historical_samples(reference, 'colima', trials)
        expected_apple = runtime_samples(reference, FIXTURES, trials)
        if docker_raw != expected_docker or docker.get('medians') != expected_medians:
            raise RuntimeError('Historical Docker comparison rows differ from the pinned archive')
        if [row for row in candidate_raw if row['lane'] == 'stock'] != expected_apple:
            raise RuntimeError('Historical Apple comparison rows differ from the pinned archive')
    rows = []
    for fixture in FIXTURES:
        paired = next((row for row in runtime if row['fixture'] == fixture), {})
        valid_pair = paired.get('passed') is True
        docker_seconds = docker.get('medians', {}).get(fixture) if docker.get('passed') else None
        row = {'fixture': fixture, 'apple_seconds': paired.get('stock') if valid_pair else None,
               'fork_seconds': paired.get('fork') if valid_pair else None, 'docker_seconds': docker_seconds,
               'fork_apple_ratio': paired.get('ratio') if valid_pair else None,
               'apple_historical': 'stock' in paired.get('historical_lanes', []),
               'docker_historical': docker.get('historical') is True,
               'docker_historical_engine_version': server_transition.get('historical'),
               'docker_current_engine_version': server_transition.get('current')}
        row['fork_docker_ratio'] = row['fork_seconds'] / docker_seconds if row['fork_seconds'] and docker_seconds else None
        fresh = [r for r in candidate_raw if r['fixture'] == fixture and r['lane'] == 'fork']
        reference = [r for r in docker_raw if r['fixture'] == fixture and r['lane'] == 'docker']
        apple = [r for r in candidate_raw if r['fixture'] == fixture and r['lane'] == 'stock']
        complete = all(len(group) == trials and {r['trial'] for r in group} == set(range(1, trials + 1))
                       and all(r['status'] == 0 and math.isfinite(r['seconds']) and r['seconds'] > 0 for r in group)
                       for group in (fresh, reference)) and not any(r.get('historical') for r in fresh)
        worst = max(r['seconds'] for r in fresh) / min(r['seconds'] for r in reference) if complete else None
        if verify_reference and complete:
            # Recompute from authenticated raw references, not an editable matrix.
            candidate_median = statistics.median(r['seconds'] for r in fresh)
            apple_median = statistics.median(r['seconds'] for r in apple)
            valid_pair = (valid_pair and paired.get('stock') == apple_median
                          and paired.get('fork') == candidate_median
                          and paired.get('ratio') == candidate_median / apple_median
                          and max(r['seconds'] for r in fresh) / min(r['seconds'] for r in apple) < 10)
        row.update(worst_fork_docker_ratio=worst,
                   passed=valid_pair and docker.get('passed') is True and complete and worst < 10)
        rows.append(row)
    (evidence / 'runtime-comparison.json').write_text(json.dumps(rows, indent=2) + '\n')
    passed = all(row['passed'] for row in rows)
    acceptance = evidence / 'runtime-comparison-acceptance.json'
    if verify_reference or not acceptance.exists():
        acceptance.write_text(json.dumps({
            'passed': passed, 'reference_verified': verify_reference,
            'failures': [row['fixture'] for row in rows if not row['passed']],
            'dockerServerVersionTransition': server_transition,
            'rule': 'Every fixture must complete; slowest candidate / fastest historical Docker sample must be below 10x.',
        }, indent=2) + '\n')
    lines = ['# Runtime performance', '', '| Workload | Apple ms | Fork ms | Docker ms | Fork/Apple | Fork/Docker |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    for row in rows:
        timings = [f'{1000 * row[key]:.1f}' if row[key] is not None else 'Not qualified'
                   for key in ('apple_seconds', 'fork_seconds', 'docker_seconds')]
        ratios = [f'{row[key]:.2f}x' if row[key] is not None else 'Not qualified'
                  for key in ('fork_apple_ratio', 'fork_docker_ratio')]
        lines.append('| ' + ' | '.join([row['fixture'], *timings, *ratios]) + ' |')
    lines += ['', 'Medians of serial trials. Docker uses an existing shared Colima VM; Apple and fork startup create a VM per container.',
              f"Historical Docker measurements use Engine {server_transition.get('historical', 'unavailable')}; the read-only current Docker oracle is Engine {server_transition.get('current', 'unavailable')}. Fork/Docker ratios compare these different dates and versions, not contemporaneous paired measurements.",
              'Apple and Docker values marked historical in runtime-comparison.json are published Q153 measurements. Only the fork candidate is newly timed; these are not contemporaneous paired runs or newly replayed reference assertions.',
              'The same-fixture 10x acceptance rule uses every raw sample: slowest current fork divided by fastest historical Docker. Missing, failed or incomplete workloads cannot qualify.',
              'A missing or failed workload has no qualified speed ratio. Raw durations and failures remain in each stage directory.',
              'Component comparisons, including intentional upstream contract differences, are retained separately in components/matrix.md.']
    (evidence / 'BENCHMARK.md').write_text('\n'.join(lines) + '\n')
    return passed


def reference_admission(evidence: Path, trials: int) -> None:
    """Check the published reference and selected Docker engine before any build."""
    from benchmark_reference import fetch, retain
    from docker_benchmark import reuse

    evidence.mkdir(parents=True, exist_ok=True)
    receipt = evidence / 'qualification.json'
    source = checkpoint()
    diagnostic = not receipt.exists()
    if diagnostic:
        result = {'kind': 'reference-only-diagnostic', 'source': source, 'passed': False,
                  'stages': [], 'failures': []}
        receipt.write_text(json.dumps(result, indent=2) + '\n')
    else:
        result = json.loads(receipt.read_text())
        first = result.get('stages', [])
        if (result.get('kind') is not None or result.get('source') != source
                or result.get('passed') is not False or len(first) != 1
                or first[0].get('name') != 'benchmark-reference'
                or first[0].get('state') != 'running'):
            raise RuntimeError('Reference admission requires the first active qualification stage')
    try:
        retain(evidence / 'benchmark-reference', fetch())
        reuse(evidence / 'docker-reference-admission', 'colima', trials)
        if checkpoint() != source:
            raise RuntimeError('Source changed during reference admission')
        if diagnostic:
            result['referenceAdmissionPassed'] = True
    except BaseException as error:
        if diagnostic:
            result['failures'].append(str(error))
        raise
    finally:
        if diagnostic:
            receipt.write_text(json.dumps(result, indent=2) + '\n')


def run(evidence: Path, trials: int) -> None:
    evidence.mkdir(parents=True, exist_ok=True)
    receipt = evidence / 'qualification.json'
    if receipt.exists():
        raise RuntimeError('Use a new evidence directory; previous failures must be preserved')
    result = {'passed': False, 'stages': [], 'failures': []}
    runner = Runner(evidence / 'stages', STORAGE)
    runner.evidence.mkdir()
    try:
        result['source'] = checkpoint()
        states = {}
        for name, dependencies, command, timeout in stages(evidence, trials):
            blocked = [dependency for dependency in dependencies if states.get(dependency) != 'passed']
            stage = {'name': name, 'state': 'blocked' if blocked else 'running', 'blocked_by': blocked}
            result['stages'].append(stage)
            receipt.write_text(json.dumps(result, indent=2) + '\n')
            if not blocked:
                # A nested command can need 10s to stop plus two 60s Bazel shutdowns
                # (each with 10s stop grace); leave time for its report to flush.
                row = runner.run('qualification', 'fork', name, 0, command, ROOT, timeout, stop_grace=180)
                stage.update(state='passed' if row['status'] == 0 else 'failed', log=row['log'], seconds=row['seconds'])
                if name == 'component-benchmarks' and row['status'] == 2:
                    review_path = evidence / 'components/comparison-review.json'
                    if review_path.exists() and json.loads(review_path.read_text()).get('completed'):
                        stage.update(state='reviewed-differences', review=str(review_path))
            states[name] = stage['state']
            receipt.write_text(json.dumps(result, indent=2) + '\n')
        if checkpoint() != result['source']:
            raise RuntimeError('Source changed during qualification')
        result['passed'] = all(state in {'passed', 'reviewed-differences'} for state in states.values())
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        receipt.write_text(json.dumps(result, indent=2) + '\n')
        benchmark_summary(evidence, trials)
        lines = ['# Container qualification', '', 'Source: `' + result.get('source', 'not admitted') + '`', '',
                 '| Layer | Result | Seconds |', '| --- | --- | ---: |']
        lines += ['| ' + row['name'] + ' | ' + row['state'] + ' | ' + str(round(row.get('seconds', 0), 2)) + ' |'
                  for row in result['stages']]
        lines += ['', 'Complete: **' + str(result['passed']) + '**', '',
                  'Raw outcomes, blocked dependencies and logs are retained in qualification.json.',
                  'Reviewed differences are expected compatibility mismatches, not passing speed measurements. Host-specific NIO checks remain separately runnable and are not claimed as passing.',
                  'SonarCloud, CodeQL and unit coverage run in GitHub; the github-quality layer verifies that workflow at this exact commit.',
                  'No release is published by this command.']
        (evidence / 'QUALIFICATION.md').write_text('\n'.join(lines) + '\n')
    if not result['passed']:
        raise SystemExit(1)


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--trials', type=int, default=7)
    parser.add_argument('--compare-only', action='store_true', help='Validate retained candidate/reference raw timing evidence only')
    parser.add_argument('--reference-admission', action='store_true', help='Diagnostic-only early historical Docker admission')
    args = parser.parse_args()
    if args.trials < 1:
        parser.error('--trials must be positive')
    if args.compare_only and args.reference_admission:
        parser.error('Select only one qualification mode')
    if args.reference_admission:
        reference_admission(args.evidence, args.trials)
    elif args.compare_only:
        if not benchmark_summary(args.evidence, args.trials, verify_reference=True):
            raise SystemExit(1)
    else:
        run(args.evidence, args.trials)


if __name__ == '__main__':
    main()
