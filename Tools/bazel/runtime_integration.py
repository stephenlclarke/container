#!/usr/bin/env python3
"""Run the original CLI integration suites in separately reported runtime layers."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET

from fork_benchmark import ROOT, digest, install_signal_handlers
from runtime_coverage import RuntimeCoverage
from runtime_benchmark import INSTALLS, PLUGINS, STATE, RuntimeRunner, build_inputs, environment, own, reset_state, start_lane, stop_owned

LAYERS = ['Containers', 'Run', 'Volumes', 'Network', 'Images', 'Build', 'System', 'Registry', 'Machine', 'K8s']
EOF_SELECTION = '^TestCLIPrimaryInputEOF/'
EOF_CASES = {
    'foregroundDedicatedRunClosesFiniteInput()',
    'prewarmedDedicatedStartClosesFiniteInput()',
    'foregroundSharedRunClosesFiniteInput()',
}
COMMIT_CASES = {'testCommitStoppedContainer()', 'testCommitRunningContainer()'}


class EOFIntegrationRunner(RuntimeRunner):
    """Expose the EOF completion marker to focused and full integration runs."""

    def command(self, lane: str, fixture: str, trial: int, args: list[str],
                timeout: int = 120, expected: str | None = None) -> dict:
        if fixture == 'setup-start':
            if lane != 'fork' or args[:2] != ['system', 'start']:
                raise RuntimeError('Integration runner encountered an unexpected service startup')
            args = [*args, '--debug']
        return super().command(lane, fixture, trial, args, timeout, expected)


def require_eof_cases(reports: Path) -> None:
    cases = [(suite.get('name'), case.get('name'), case)
             for xml in reports.rglob('test.xml')
             for suite in ET.parse(xml).iter('testsuite')
             for case in suite.findall('testcase')]
    identities = [(suite, name) for suite, name, _ in cases]
    expected = {('IntegrationTests.TestCLIPrimaryInputEOF', name) for name in EOF_CASES}
    if len(identities) != 3 or set(identities) != expected or any(
            case.find('skipped') is not None or case.find('failure') is not None
            or case.find('error') is not None or case.get('result') != 'completed'
            for _, _, case in cases):
        raise RuntimeError('Focused EOF integration did not complete all three original cases')


def require_commit_cases(reports: Path) -> None:
    """The upstream commit suite must not disappear from the full CLI inventory."""
    cases = [case for xml in reports.rglob('test.xml')
             for suite in ET.parse(xml).iter('testsuite')
             if suite.get('name') == 'IntegrationTests.TestCLICommitCommand'
             for case in suite.findall('testcase')]
    if (len(cases) != len(COMMIT_CASES) or {case.get('name') for case in cases} != COMMIT_CASES
            or any(case.find('skipped') is not None or case.find('failure') is not None
                   or case.find('error') is not None or case.get('result') != 'completed'
                   for case in cases)):
        raise RuntimeError('Container commit integration did not complete both upstream cases')


def owned_cli_processes(executable: Path, records: Path) -> dict[int, str]:
    """Match the recorded PID, birth time and exact executable before signalling."""
    found = {}
    allowed = {str(executable)}
    if executable.name == 'container':
        # CLI dispatch uses exec for plugins, preserving the recorded PID/birth.
        allowed.update(str(executable.parent.parent / 'libexec/container/plugins' / name / 'bin' / name)
                       for name in PLUGINS)
    listing = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=10)
    for line in listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or fields[1] not in allowed:
            continue
        pid = int(fields[0])
        record = records / (str(pid) + '.json')
        if not record.exists():
            continue
        saved = json.loads(record.read_text())
        started = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='],
                                 env=dict(os.environ, TZ='UTC'), capture_output=True, text=True, timeout=10).stdout.strip()
        if saved == {'pid': pid, 'started': started, 'executable': str(executable)}:
            found[pid] = started
    return found


def stop_test_children(executable: Path, records: Path) -> list[int]:
    """Bazel/Swift children may start new sessions, outside the driver's group."""
    owned = owned_cli_processes(executable, records)
    for number in (signal.SIGTERM, signal.SIGKILL):
        current = owned_cli_processes(executable, records)
        for pid, started in owned.items():
            if current.get(pid) == started:
                try:
                    os.kill(pid, number)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + (3 if number == signal.SIGTERM else 2)
        while owned_cli_processes(executable, records) and time.monotonic() < deadline:
            time.sleep(.1)
    if owned_cli_processes(executable, records):
        raise RuntimeError('Owned integration CLI processes survived cleanup')
    return sorted(owned)


def test_filter(layer: str) -> str:
    suites = sorted(p.stem for p in (ROOT / 'Tests/IntegrationTests' / layer).glob('*.swift')
                    if p.stem.startswith('Test'))
    if not suites:
        raise RuntimeError('No integration suites found for ' + layer)
    return '^(' + '|'.join(suites) + ')/'


def verify_prepared(prepared: Path) -> None:
    inputs = json.loads((prepared / 'source-inputs.json').read_text())
    current = {str(p.relative_to(ROOT)): digest(p) for p in sorted((ROOT / 'Sources').rglob('*')) if p.is_file()}
    if current != inputs['source_sha256']['fork']:
        raise RuntimeError('Product sources changed after runtime preparation')
    fingerprint = json.loads((prepared / 'fork-fingerprint.json').read_text())
    if digest(ROOT / 'Package.resolved') != fingerprint['package_lock_sha256']:
        raise RuntimeError('Dependencies changed after runtime preparation')
    if inputs.get('build_inputs') != build_inputs():
        raise RuntimeError('Build inputs changed or are missing; prepare fresh runtime evidence')


def retain_layer_reports(log: Path, destination: Path) -> int:
    match = re.search(r'^Evidence: (.+)\.log$', log.read_text(), re.M)
    if not match:
        raise RuntimeError('Integration layer omitted its Bazel evidence location')
    reports = Path(match[1] + '.events.tests')
    shutil.copytree(reports, destination)
    executed = sum(1 for xml in destination.rglob('test.xml')
                   for case in ET.parse(xml).iter('testcase') if case.find('skipped') is None)
    if not executed:
        raise RuntimeError('Integration selection ran no test cases: ' + str(log))
    return executed


def run(evidence: Path, prepared: Path, layers: list[str], selection: str | None = None,
        coverage: bool = False) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    verify_prepared(prepared)
    for name in ['source-inputs.json', 'fork-fingerprint.json', 'guest-artifact.json', 'builder-artifact.json']:
        shutil.copy2(prepared / name, evidence / name)
    runner = EOFIntegrationRunner(evidence, STATE)
    executable = INSTALLS / 'fork/install/bin/container'
    records = evidence / 'processes'
    records.mkdir()
    result = {'passed': False, 'layers': layers, 'selection': selection, 'failures': [], 'coverage': coverage}
    profiling = None
    with (INSTALLS / 'benchmark.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            if coverage:
                profiling = RuntimeCoverage(runner, layers == LAYERS and selection is None)
                profiling.prepare()
            stop_owned('fork')
            metadata = json.loads((evidence / 'fork-fingerprint.json').read_text())
            if reset_state('fork', metadata['init_image'], metadata['builder_image']) != metadata['kernel_sha256']:
                raise RuntimeError('Kernel changed after runtime preparation')
            start_lane(runner, 'fork')
            state = STATE / 'fork/integration'
            own(state, 'integration')
            config = state / 'home'
            config.mkdir(exist_ok=True)
            env = dict(environment('fork'), CONTAINER_CLI_PATH=str(ROOT / 'Tools/bazel/integration_cli.py'),
                       CLITEST_REAL_CLI=str(executable), CLITEST_PROCESS_DIRECTORY=str(records),
                       CONTAINER_RUNTIME_TESTS_SERIAL='1', CLITEST_LOG_ROOT=str(evidence / 'fixtures'),
                       CLITEST_APISERVER_LOG=str(STATE / 'fork/logs/container-apiserver.log'),
                       CONTAINER_REGISTRY_ANONYMOUS_HOSTS='ghcr.io,docker.io,registry-1.docker.io',
                       CLITEST_SCRATCH_ROOT=str(state / 'scratch'),
                       KUBECONFIG=str(config / 'kubeconfig'), DOCKER_CONFIG=str(config / '.docker'))
            if profiling:
                env['CLITEST_RUNTIME_PROFILE'] = profiling.environment['LLVM_PROFILE_FILE']
            names = ['CONTAINER_APP_ROOT', 'CONTAINER_INSTALL_ROOT', 'CONTAINER_SERVICE_NAMESPACE',
                     'XDG_CONFIG_HOME', 'CONTAINER_REGISTRY_ANONYMOUS_HOSTS', 'CONTAINER_CLI_PATH',
                     'CONTAINER_RUNTIME_TESTS_SERIAL', 'CLITEST_LOG_ROOT', 'CLITEST_SCRATCH_ROOT', 'CLITEST_REAL_CLI', 'CLITEST_PROCESS_DIRECTORY',
                     'CLITEST_APISERVER_LOG',
                     'KUBECONFIG', 'DOCKER_CONFIG', 'CLITEST_RUNTIME_PROFILE']
            flags = ['--test_env=' + name + '=' + env[name] for name in names if name in env]
            mode = 'coverage' if profiling else 'test'
            configuration = 'runtime-coverage' if profiling else 'release'
            if profiling:
                flags += ['--combined_report=lcov', '--repo_env=GIT_COMMIT=' + profiling.result['revision']]
            for layer in ['Warmup', *layers]:
                selected = '^ImageWarmup/' if layer == 'Warmup' else selection or test_filter(layer)
                test_timeout = 300 if selection == EOF_SELECTION else 1800
                runner.env = env
                row = runner.run('integration', 'fork', layer.lower(), 0,
                                 [str(ROOT / 'Tools/bazel/run.sh'), mode, '//:runtime-integration-tests',
                                  '--test_filter=' + selected, '--strategy=TestRunner=local',
                                  '--config=' + configuration, '--nocache_test_results',
                                  '--test_timeout=' + str(test_timeout), *flags],
                                 ROOT, timeout=test_timeout + 60)
                try:
                    row['executed_tests'] = retain_layer_reports(Path(row['log']), evidence / (layer.lower() + '-reports'))
                    if layer == 'Run' and selection == EOF_SELECTION:
                        require_eof_cases(evidence / 'run-reports')
                    if layer == 'Containers' and (selection is None or selection == '^TestCLICommitCommand/'):
                        require_commit_cases(evidence / 'containers-reports')
                except (OSError, RuntimeError) as error:
                    row['report_error'] = str(error)
                    if row['status'] == 0:
                        raise
                if row['status']:
                    raise RuntimeError('Integration layer failed: ' + layer + '; see ' + row['log'])
                if profiling:
                    profiling.retain_layer(Path(row['log']), layer)
                if layer == 'Build':
                    # Build tests share a builder; System disk accounting needs an empty store.
                    runner.command('fork', 'build-cleanup', 0, ['builder', 'delete', '--force'])
            result['passed'] = True
        except BaseException as error:
            result['failures'].append(str(error))
            raise
        finally:
            cleanup_errors = []
            try:
                result['stopped_children'] = stop_test_children(executable, records)
                if result['passed'] and result['stopped_children']:
                    raise RuntimeError('Integration tests left running CLI children')
            except BaseException as error:
                cleanup_errors.append(str(error))
            try:
                stop_owned('fork')
                logs = STATE / 'fork/logs'
                if logs.exists():
                    shutil.copytree(logs, evidence / 'server-logs')
                verify_prepared(prepared)
            except BaseException as error:
                cleanup_errors.append(str(error))
            finally:
                if profiling:
                    try:
                        profiling.finish(result['passed'] and not cleanup_errors)
                    except BaseException as error:
                        cleanup_errors.append(str(error))
                if cleanup_errors:
                    result['passed'] = False
                    result['failures'].extend(cleanup_errors)
                result['operations'] = runner.rows
                (evidence / 'integration.json').write_text(json.dumps(result, indent=2) + '\n')
            if cleanup_errors:
                raise RuntimeError('; '.join(cleanup_errors))


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--prepared', type=Path, required=True, help='Matching runtime preparation/benchmark evidence')
    parser.add_argument('--layer', choices=LAYERS, action='append')
    parser.add_argument('--test-filter', help='Focused selection within one explicitly selected layer; recorded as partial coverage')
    parser.add_argument('--coverage', action='store_true', help='Collect runtime and per-layer integration line coverage')
    args = parser.parse_args()
    if args.test_filter and len(args.layer or []) != 1:
        parser.error('--test-filter requires exactly one --layer')
    run(args.evidence, args.prepared, args.layer or LAYERS, args.test_filter, args.coverage)


if __name__ == '__main__':
    main()
