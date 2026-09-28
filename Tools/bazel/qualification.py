#!/usr/bin/env python3
"""Run the reduced release gates in dependency order and retain every stage outcome."""

import argparse
import json
from pathlib import Path
import sys

from fork_benchmark import ROOT, STORAGE, Runner, install_signal_handlers
from quality import checkpoint
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
        ('tools', [], make + ['bazel-tools-test'], 300),
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
        ('guest', ['dependencies'], script('guest_artifact', '--evidence', evidence / 'guest'), 1800),
        ('guest-runc', ['guest'], script('guest_artifact', '--with-runc', '--evidence', evidence / 'guest-runc'), 1800),
        ('linux', ['guest'], script('linux_tests', '--evidence', evidence / 'linux'), 1800),
        ('builder', ['tools'], script('builder_artifact', '--evidence', evidence / 'builder'), 1800),
        ('services', ['tools'], script('service_artifacts', '--evidence', evidence / 'services'), 1800),
        ('service-integration', ['container', 'services'], script('service_integration', '--evidence', evidence / 'service-integration'), 900),
        ('runtime-smoke', ['container', 'guest', 'linux', 'builder'], script('runtime_benchmark', '--prepare', '--trials', 1,
                    '--guest-artifact', evidence / 'guest/guest-artifact.json',
                    '--builder-artifact', evidence / 'builder/builder-artifact.json', '--evidence', prepared), 3600),
        ('vm-integration', ['runtime-smoke', 'guest-runc'], script('vm_integration', '--guest-artifact', evidence / 'guest-runc/guest-artifact.json',
                    '--evidence', evidence / 'vm-integration'), 3600),
        ('integration', ['vm-integration'], script('runtime_integration', '--prepared', prepared, '--evidence', evidence / 'integration', '--coverage'), 9000),
        ('coverage', ['container'], script('coverage', '--evidence', evidence / 'coverage'), 1800),
        ('combined-coverage', ['coverage', 'integration'], script('combined_coverage', '--unit', evidence / 'coverage',
                    '--integration', evidence / 'integration/coverage', '--evidence', evidence / 'combined-coverage'), 600),
        ('codeql', ['container'], script('codeql', '--evidence', evidence / 'codeql'), 5400),
        ('quality', ['combined-coverage'], script('quality', '--coverage', evidence / 'combined-coverage', '--evidence', evidence / 'quality'), 1800),
        ('component-benchmarks', ['dependencies', 'container', 'builder'], script('fork_benchmark',
                    '--evidence', evidence / 'components', '--scratch', component_scratch, *component_args), 10800),
        ('runtime-benchmark', ['integration'], script('runtime_benchmark', '--prepared', prepared,
                    '--trials', trials, '--evidence', evidence / 'runtime-benchmark'), 1800),
        ('docker-benchmark', ['runtime-smoke'], script('docker_benchmark', '--context', 'colima',
                    '--trials', trials, '--evidence', evidence / 'docker-benchmark'), 1800),
        ('release', ['maintenance', 'documentation', 'host', 'services', 'service-integration', 'integration', 'combined-coverage', 'quality', 'codeql'], script('release_artifact',
                    '--prepared', prepared, '--service-artifacts', evidence / 'services/service-artifacts.json',
                    '--notarize', '--evidence', evidence / 'release'), 3600),
        ('install', ['release'], script('release_install', '--release', evidence / 'release', '--evidence', evidence / 'install'), 900),
    ]


def benchmark_summary(evidence: Path) -> None:
    runtime_path = evidence / 'runtime-benchmark/matrix.json'
    docker_path = evidence / 'docker-benchmark/acceptance.json'
    runtime = json.loads(runtime_path.read_text()) if runtime_path.exists() else []
    docker = json.loads(docker_path.read_text()) if docker_path.exists() else {}
    rows = []
    for fixture in FIXTURES:
        paired = next((row for row in runtime if row['fixture'] == fixture), {})
        valid_pair = paired.get('passed') is True
        docker_seconds = docker.get('medians', {}).get(fixture) if docker.get('passed') else None
        row = {'fixture': fixture, 'apple_seconds': paired.get('stock') if valid_pair else None,
               'fork_seconds': paired.get('fork') if valid_pair else None, 'docker_seconds': docker_seconds,
               'fork_apple_ratio': paired.get('ratio') if valid_pair else None}
        row['fork_docker_ratio'] = row['fork_seconds'] / docker_seconds if row['fork_seconds'] and docker_seconds else None
        rows.append(row)
    (evidence / 'runtime-comparison.json').write_text(json.dumps(rows, indent=2) + '\n')
    lines = ['# Runtime performance', '', '| Workload | Apple ms | Fork ms | Docker ms | Fork/Apple | Fork/Docker |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    for row in rows:
        timings = [f'{1000 * row[key]:.1f}' if row[key] is not None else 'Not qualified'
                   for key in ('apple_seconds', 'fork_seconds', 'docker_seconds')]
        ratios = [f'{row[key]:.2f}x' if row[key] is not None else 'Not qualified'
                  for key in ('fork_apple_ratio', 'fork_docker_ratio')]
        lines.append('| ' + ' | '.join([row['fixture'], *timings, *ratios]) + ' |')
    lines += ['', 'Medians of serial trials. Docker uses an existing shared Colima VM; Apple and fork startup create a VM per container.',
              'A missing or failed workload has no qualified speed ratio. Raw durations and failures remain in each stage directory.',
              'Component comparisons, including intentional upstream contract differences, are retained separately in components/matrix.md.']
    (evidence / 'BENCHMARK.md').write_text('\n'.join(lines) + '\n')


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
                row = runner.run('qualification', 'fork', name, 0, command, ROOT, timeout)
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
        benchmark_summary(evidence)
        lines = ['# Container qualification', '', 'Source: `' + result.get('source', 'not admitted') + '`', '',
                 '| Layer | Result | Seconds |', '| --- | --- | ---: |']
        lines += ['| ' + row['name'] + ' | ' + row['state'] + ' | ' + str(round(row.get('seconds', 0), 2)) + ' |'
                  for row in result['stages']]
        lines += ['', 'Complete: **' + str(result['passed']) + '**', '',
                  'Raw outcomes, blocked dependencies and logs are retained in qualification.json.',
                  'Reviewed differences are expected compatibility mismatches, not passing speed measurements. Host-specific NIO checks remain separately runnable and are not claimed as passing.',
                  'No release is published by this command.']
        (evidence / 'QUALIFICATION.md').write_text('\n'.join(lines) + '\n')
    if not result['passed']:
        raise SystemExit(1)


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--trials', type=int, default=7)
    args = parser.parse_args()
    if args.trials < 1:
        parser.error('--trials must be positive')
    run(args.evidence, args.trials)


if __name__ == '__main__':
    main()
