#!/usr/bin/env python3
"""Benchmark matching Apple/fork sources in disposable, pinned Bazel fixtures.

Usage: python3 Tools/bazel/fork_benchmark.py --help
Source checkouts and installed container services are never modified.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import shutil
import statistics
import stat
import subprocess
import tarfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

from bazel_environment import bazel_environment

ROOT = Path(__file__).resolve().parents[2]
STORAGE = Path('/Volumes/SSD/cf/container-only')
BAZEL = Path('/Volumes/SSD/cf/bazel/bootstrap/bazel-8.8.0-darwin-arm64')
BAZEL_SHA = 'f0ac192aba2ccaa373cdfd527d4c407cc492c1296a2f11a4b67563e4d5aa9acb'
PAIRS = {
    'containerization': {
        'repo': '/Users/sclarke/github/containerization',
        'stock': 'bc994b88df46207fad7775b0eabc51947e315881',
        'fork': '7b9eb0a77ff615d764fbbf52125e2b6cdd846db8',
        'products': ['ContainerizationExtras', 'ContainerizationArchive',
                     'ContainerizationEXT4', 'ContainerizationOCI', 'Containerization'],
        'tests': ['ContainerizationExtrasTests', 'ContainerizationArchiveTests',
                  'ContainerizationEXT4Tests', 'ContainerizationOCITests'],
    },
    'container': {
        'repo': '/Users/sclarke/github/container',
        'stock': '4a7d8615241b8ddecfd3bf225cd7c44f4b2ccf7c',
        'fork': 'cb30a2e0fed1749794ebcb09f0fffed71ca12847',
        'products': ['container', 'container-apiserver', 'container-core-images',
                     'container-network-vmnet', 'container-runtime-linux',
                     'machine-apiserver', 'k8s'],
        'tests': ['SocketForwarderTests', 'ContainerOSTests',
                  'ContainerPersistenceTests', 'ContainerResourceTests',
                  'ContainerNetworkServerTests', 'TerminalProgressTests',
                  'DNSServerTests', 'ContainerBuildTests'],
    },
    'swift-nio-ssl': {
        'repo': '/Users/sclarke/github/swift-nio-ssl',
        'stock': '322f3c2a4a21df31c84ca416bf65ee5e9059e440',
        'fork': '17ab11cd2dac5cfc4760a37cb2e0f955d7629439',
        'products': ['NIOSSL'],
        'tests': ['NIOSSLTests'],
    },
    'grpc-swift-nio-transport': {
        'repo': '/Users/sclarke/github/grpc-swift-nio-transport',
        'stock': 'ff4420d7c33cc998a590b0761630d67f76bc291e',
        'fork': 'bb91b124b6f20cf82edec4b379bdcf8838f98343',
        'products': ['GRPCNIOTransportCore', 'GRPCNIOTransportHTTP2'],
        'tests': ['GRPCNIOTransportCoreTests', 'GRPCNIOTransportHTTP2Tests'],
    },
    'container-builder-shim': {
        'repo': '/Users/sclarke/github/container-builder-shim',
        'stock': '5dc4286e5adbeb7dac189b22b7d5aab336942fe2',
        'fork': '016040197215684db474181b444767eb58797cfa',
    },
}
OCI_FILES = ['ContentWriterTests.swift', 'DescriptorDecodingTests.swift',
             'DigestValidationTests.swift', 'LocalContentStoreTests.swift',
             'LocalOCILayoutClientTests.swift', 'OCIImageTests.swift',
             'OCIPlatformTests.swift', 'OCISpecTests.swift', 'ReferenceTests.swift',
             'SpecRedactionTests.swift']
TLS_CASES = ('repeated_handshakes', 'many_writes_512b')


def historical_cli_help_phase_ratios(lanes: dict[str, list[dict]]) -> dict[str, float]:
    """Compare the first CLI invocation only with the historical first invocation.

    The authenticated original Runner.cli runs help, then version, for each
    trial 0 through 10. Later help invocations therefore form a separate
    repeated-execution phase. The caller has already verified that original
    workload and order with component_reference.validate_inputs.
    """
    trials = {}
    for lane in ('stock', 'fork'):
        rows = lanes[lane]
        if len(rows) != 11:
            raise RuntimeError('Historical CLI help requires eleven trials per lane')
        by_trial = {}
        for row in rows:
            trial = row.get('trial')
            seconds = row.get('seconds')
            status = row.get('status')
            historical = row.get('historical')
            if (type(trial) is not int or trial not in range(11) or trial in by_trial
                    or type(seconds) not in (int, float) or not math.isfinite(seconds)
                    or seconds <= 0 or type(status) is not int or status != 0
                    or row.get('component') != 'container' or row.get('fixture') != 'cli-run-help'
                    or row.get('lane') != lane
                    or (historical is not True if lane == 'stock'
                        else historical is not None and historical is not False)):
                raise RuntimeError('Historical CLI help trial identity or measurement is invalid')
            by_trial[trial] = seconds
        if set(by_trial) != set(range(11)):
            raise RuntimeError('Historical CLI help trial inventory is incomplete')
        trials[lane] = by_trial
    return {
        'first-invocation': trials['fork'][0] / trials['stock'][0],
        'repeated-invocation': max(trials['fork'][trial] for trial in range(1, 11))
                               / min(trials['stock'][trial] for trial in range(1, 11)),
    }


def tls_samples(text: str, fixture: str) -> list[float]:
    """Reject a debug build, skipped workload, or incomplete upstream measurement."""
    if 'DEBUG MODE' in text:
        raise ValueError('TLS performance executable was built in debug mode')
    lines = re.findall(r'^measuring: ' + re.escape(fixture) + r': (.+)$', text, re.M)
    if len(lines) != 1:
        raise ValueError('TLS performance executable omitted the selected workload')
    values = [float(value.strip()) for value in lines[0].split(',') if value.strip()]
    if len(values) != 10 or any(not math.isfinite(value) or value <= 0 for value in values):
        raise ValueError('TLS performance executable omitted ten valid measurements')
    return values


def tls_executable(files: str, execution: Path) -> Path:
    """Separate the linked executable from the same-named DWARF debug file."""
    candidates = [execution / name for name in files.splitlines()
                  if name.endswith('/NIOSSLPerformanceTester.rspm.__impl')
                  and '/Contents/Resources/DWARF/' not in name]
    if len(candidates) != 1:
        raise RuntimeError('TLS benchmark build did not identify one executable')
    return candidates[0]


def output(args: list[str], cwd: Path | None = None, env: dict | None = None) -> str:
    environment = os.environ if env is None else env
    if str(args[0]) == str(BAZEL):
        environment = bazel_environment(environment)
    return subprocess.check_output(args, cwd=cwd, env=environment, text=True, timeout=60).strip()


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def archive(repo: str | Path, revision: str, dest: Path, paths: tuple | list = ()) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(['git', '-C', str(repo), 'archive', revision, *paths],
                            stdout=subprocess.PIPE)
    with proc.stdout as stream:
        with tarfile.open(fileobj=stream, mode='r|') as tar:
            tar.extractall(dest, filter='data')
    if proc.wait():
        raise RuntimeError(f'git archive failed: {repo} {revision}')


def install_signal_handlers() -> None:
    """Let resource-owning Python commands execute their finally blocks on stop."""
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(number, interrupted)


def prepare(component: str, lane: str, scratch: Path) -> Path:
    pair = PAIRS[component]
    base = scratch / component / lane
    workspace = base / 'workspace'
    if workspace.exists():
        return workspace
    if component == 'container-builder-shim':
        archive(pair['repo'], pair[lane], workspace)
        # Same benchmark and mock/test sources, including warmup error checking.
        for path in (workspace / 'pkg/prefetch').glob('*_test.go'):
            path.unlink()
        names = output(['git', '-C', pair['repo'], 'ls-tree', '-r', '--name-only',
                        pair['stock'], 'pkg/prefetch']).splitlines()
        archive(pair['repo'], pair['stock'], workspace,
                [n for n in names if n.endswith('_test.go')])
        archive(pair['repo'], pair['fork'], workspace, ['pkg/prefetch/benchmark_test.go'])
        inputs = {str(p.relative_to(base)): digest(p) for p in workspace.rglob('*')
                  if p.is_file() and (p.suffix == '.go' or p.name in {'go.mod', 'go.sum', 'modules.txt'})}
        (base / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
        return workspace
    root_revision = pair[lane] if component == 'container' else PAIRS['container']['fork']
    archive(PAIRS['container']['repo'], root_revision, workspace)
    source = workspace
    if component != 'container':
        source = base / 'component'
        archive(pair['repo'], pair[lane], source)
    if component == 'swift-nio-ssl':
        # Both libraries run Apple's identical workload and certificates.
        performance = 'Sources/NIOSSLPerformanceTester'
        shutil.rmtree(source / performance)
        archive(pair['repo'], pair['stock'], source, [performance])
    # Use the same stock tests on both sides, never compare different test counts.
    for suite in pair['tests']:
        directory = source / 'Tests' / suite
        shutil.rmtree(directory)
        archive(pair['repo'], pair['stock'], source, ['Tests/' + suite])
        if suite == 'ContainerizationOCITests':
            for path in directory.glob('*.swift'):
                if path.name not in OCI_FILES:
                    path.unlink()
    for name in ['Tools/bazel', 'Tools/ContainerSemanticHelper']:
        shutil.copytree(ROOT / name, workspace / name, dirs_exist_ok=True)
    for name in ['MODULE.bazel', 'MODULE.bazel.lock', '.bazelrc', '.bazelversion', 'Package.resolved']:
        shutil.copy2(ROOT / name, workspace / name)
    containerization_source = source if component == 'containerization' else None
    if component == 'container' and lane == 'stock':
        stock_lock = json.loads(output(['git', '-C', pair['repo'], 'show', pair['stock'] + ':Package.resolved']))
        stock_pin = next(p for p in stock_lock['pins'] if p['identity'] == 'containerization')
        containerization_source = base / 'containerization'
        archive(PAIRS['containerization']['repo'], stock_pin['state']['revision'], containerization_source)
        lock = json.loads((workspace / 'Package.resolved').read_text())
        lock['pins'] = [stock_pin if p['identity'] == 'containerization' else p for p in lock['pins']]
        (workspace / 'Package.resolved').write_text(json.dumps(lock, indent=2) + '\n')
    dependencies = workspace / 'Tools/bazel/dependencies.bzl'
    data = dependencies.read_text()
    data = data.replace('for identity, test_targets in packages.items():',
                        'for identity in packages:\n'
                        f'                test_targets = {pair["tests"]!r} if identity == "{component}" else []')
    data = data.replace('test_targets = list({target: True for target in test_targets}),',
                        'test_targets = test_targets,')
    local_sources = {component: source} if component != 'container' else {}
    if containerization_source is not None:
        local_sources['containerization'] = containerization_source
    for identity, local_source in local_sources.items():
        data = data.replace('                pin = pins[identity]',
                            f'                if identity == "{identity}":\n'
                            f'                    local_swift_package(path = "{local_source}", **options)\n'
                            '                    continue\n'
                            '                pin = pins[identity]')
    dependencies.write_text(data)
    repo = '@swiftpkg_' + component.replace('-', '_') + '//:'
    labels = [repo + item + '.rspm' for item in pair['products']]
    (workspace / 'BUILD.bazel').write_text(
        'load("//Tools/bazel:layer_build.bzl", "layer_build")\n'
        'exports_files(["Package.resolved"])\n'
        f'layer_build(name="component", testonly=True, deps={labels!r})\n')
    # Every fixture file and importer adaptation is retained by hash.
    inputs = {str(p.relative_to(base)): digest(p) for p in base.rglob('*')
              if p.is_file()}
    (base / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    return workspace


COMMAND_LOCK_ENV = 'CONTAINER_QUALIFICATION_COMMAND_LOCK'


@contextmanager
def command_lease(environment: dict, *, exclusive: bool = False):
    """Keep recovery excluded while a command or its controller can still act."""
    path = environment.get(COMMAND_LOCK_ENV)
    if not path:
        yield ()
        return
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o022):
            raise RuntimeError('Qualification command lease is not a private single-owner file')
        fcntl.flock(descriptor, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        yield (descriptor,)
    finally:
        os.close(descriptor)


class Runner:
    def __init__(self, evidence: Path, scratch: Path) -> None:
        self.evidence = evidence
        self.scratch = scratch
        self.rows: list[dict] = []
        self.reference_rows: list[dict] = []
        self.env = dict(os.environ, TMPDIR=str(STORAGE / 'tmp') + '/', CI='1')

    def run(self, component: str, lane: str, fixture: str, trial: int,
            args: list[str], cwd: Path, timeout: int = 600, stop_grace: int = 10) -> dict:
        number = len(self.rows)
        stem = f'{number:03}-{component}-{lane}-{fixture}-{trial}'
        log = self.evidence / (stem + '.log')
        print(stem, flush=True)
        start = time.monotonic_ns()
        interrupted = None
        environment = bazel_environment(self.env) if str(args[0]) == str(BAZEL) else self.env
        with command_lease(self.env) as command_descriptors, log.open('w') as stream:
            try:
                # POSIX wait(timeout=...) polls with sleeps of up to 50 ms.
                # Keep the deadline on a watchdog so timing ends at child exit.
                with subprocess.Popen(args, cwd=cwd, env=environment, stdin=subprocess.DEVNULL, stdout=stream,
                                      stderr=subprocess.STDOUT, start_new_session=True,
                                      pass_fds=command_descriptors) as process:
                    expired = threading.Event()

                    def stop_group(grace: int):
                        try:
                            os.killpg(process.pid, signal.SIGTERM)
                            deadline = time.monotonic() + grace
                            while time.monotonic() < deadline:
                                # Darwin may return EPERM for a group containing
                                # only reparented zombies. Check for live members
                                # instead of treating signal-zero as a liveness API.
                                groups = subprocess.check_output(
                                    ['ps', '-axo', 'pgid=,stat='], text=True, timeout=3)
                                live = any(parts[0] == str(process.pid) and not parts[1].startswith('Z')
                                           for line in groups.splitlines() if len(parts := line.split()) == 2)
                                if not live:
                                    return
                                time.sleep(0.05)
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass  # The owned process group already exited.

                    def expire():
                        if process.poll() is None:
                            expired.set()
                            stop_group(10)

                    watchdog = threading.Timer(timeout, expire)
                    watchdog.daemon = True
                    watchdog.start()
                    try:
                        status = process.wait()
                    except BaseException as error:
                        watchdog.cancel()
                        watchdog.join()
                        stop_group(stop_grace if isinstance(error, (KeyboardInterrupt, SystemExit)) and not expired.is_set() else 10)
                        process.wait()
                        raise
                    finally:
                        watchdog.cancel()
                        watchdog.join()
                    if expired.is_set():
                        status = 124
            except (KeyboardInterrupt, SystemExit) as error:
                status = 130
                interrupted = error
        elapsed = (time.monotonic_ns() - start) / 1e9
        row = dict(component=component, lane=lane, fixture=fixture, trial=trial,
                   seconds=elapsed, status=status, command=[str(a) for a in args], log=str(log))
        self.rows.append(row)
        (self.evidence / 'results.json').write_text(json.dumps(self.rows, indent=2) + '\n')
        print(f'  {elapsed:.3f}s status={status}', flush=True)
        if status:
            print(log.read_text()[-6000:], flush=True)
        if interrupted:
            raise interrupted
        return row

    def bazel(self, component: str, lane: str, fixture: str, trial: int,
              command: str, targets: list[str], extra: tuple | list = ()) -> dict:
        workspace = self.scratch / component / lane / 'workspace'
        bep = self.evidence / f'{len(self.rows):03}.events.json'
        args = [str(BAZEL), '--output_user_root=' + str(STORAGE / 'paired-output'), command,
                '--repository_cache=' + str(STORAGE / 'repositories'),
                '--build_event_json_file=' + str(bep), *targets, *extra]
        row = self.run(component, lane, fixture, trial, args, workspace, timeout=1800)
        if bep.exists():
            row['events'] = str(bep)
            subprocess.run(['/usr/bin/python3', str(ROOT / 'Tools/bazel/retain_tests.py'), str(bep)],
                           check=True, stdout=subprocess.DEVNULL)
        return row

    @contextmanager
    def bazel_session(self, component: str, lanes=('stock', 'fork')):
        """Shut down both owned servers after success, failure, or interruption."""
        try:
            yield
        finally:
            failures = []
            for lane in lanes:
                try:
                    row = self.run(component, lane, 'cleanup-bazel', 0,
                                   [str(BAZEL), '--output_user_root=' + str(STORAGE / 'paired-output'),
                                    'shutdown'], self.scratch / component / lane / 'workspace', timeout=60)
                    if row['status']:
                        failures.append(lane)
                except BaseException as error:
                    failures.append(f'{lane}: {type(error).__name__}')
            if failures:
                raise RuntimeError('Bazel cleanup failed: ' + ', '.join(failures))

    def tls(self, lanes=('stock', 'fork')) -> None:
        """Measure identical optimized upstream workloads directly, without Bazel startup."""
        component = 'swift-nio-ssl'
        target = '@swiftpkg_swift_nio_ssl//:NIOSSLPerformanceTester.rspm'
        bazel = [str(BAZEL), '--output_user_root=' + str(STORAGE / 'paired-output')]
        binaries = {}
        identity = {'source': PAIRS[component], 'configuration': 'release', 'binaries': {},
                    'workloads': {}, 'method': 'Three alternating process trials; monotonic wall time includes startup, one warmup and ten upstream samples. Upstream Date-based samples are retained as diagnostics, not used for the speed ratio.'}
        for lane in lanes:
            workspace = self.scratch / component / lane / 'workspace'
            row = self.bazel(component, lane, 'prepare-tls', 0, 'build', [target], ['--config=release'])
            if row['status']:
                return
            execution = Path(output(bazel + ['info', 'execution_root'], workspace, self.env))
            files = output(bazel + ['cquery', target, '--config=release', '--output=files'], workspace, self.env)
            binary = tls_executable(files, execution)
            binaries[lane] = binary
            identity['binaries'][lane] = {'path': str(binary), 'sha256': digest(binary)}
            source = self.scratch / component / lane / 'component/Sources/NIOSSLPerformanceTester'
            identity['workloads'][lane] = {str(p.relative_to(source)): digest(p)
                                           for p in sorted(source.rglob('*')) if p.is_file()}
        if len(lanes) == 2 and identity['workloads']['stock'] != identity['workloads']['fork']:
            raise RuntimeError('TLS performance workloads differ between lanes')
        (self.evidence / 'tls-benchmarks.json').write_text(json.dumps(identity, indent=2) + '\n')
        failed = set()
        for trial in range(3):
            for lane in (('stock', 'fork') if trial % 2 == 0 else ('fork', 'stock')):
                for fixture in TLS_CASES:
                    if (lane, fixture) in failed:
                        continue
                    if digest(binaries[lane]) != identity['binaries'][lane]['sha256']:
                        raise RuntimeError('TLS benchmark executable changed during measurement')
                    row = self.run(component, lane, 'tls-' + fixture, trial,
                                   [str(binaries[lane]), fixture], binaries[lane].parent, timeout=120)
                    if not row['status']:
                        try:
                            row['upstream_samples_seconds'] = tls_samples(Path(row['log']).read_text(), fixture)
                        except ValueError as error:
                            row.update(status=65, validation_error=str(error))
                    if row['status']:
                        failed.add((lane, fixture))

    def report(self) -> None:
        (self.evidence / 'results.json').write_text(json.dumps(self.rows, indent=2) + '\n')
        rows = self.rows + self.reference_rows
        if self.reference_rows:
            (self.evidence / 'historical-results.json').write_text(json.dumps(self.reference_rows, indent=2) + '\n')
        matrix = []
        fixtures = sorted({(r['component'], r['fixture']) for r in rows
                           if r['fixture'] not in {'prepare-build', 'prepare-linux-build', 'prepare-tls', 'toolchain', 'cleanup-bazel'}})
        suite = ET.Element('testsuite', name='fork-vs-apple')
        for row in self.rows:
            if row.get('historical'):
                continue
            case = ET.SubElement(suite, 'testcase', classname=row['component'],
                                 name=f"{row['lane']}/{row['fixture']}/{row['trial']}",
                                 time=str(row['seconds']))
            if row['status']:
                ET.SubElement(case, 'failure', message=f"exit {row['status']}").text = row['log']
        for component, fixture in fixtures:
            lanes = {lane: [r for r in rows if r['component'] == component and
                            r['fixture'] == fixture and r['lane'] == lane]
                     for lane in ['stock', 'fork']}
            if not all(lanes.values()):
                if component == 'container' and fixture == 'cli-run-help' and self.reference_rows:
                    raise RuntimeError('Historical CLI help is missing an entire measurement lane')
                continue
            historical_lanes = [lane for lane, values in lanes.items() if all(r.get('historical') for r in values)]
            comparison = 'retained-paired-history' if len(historical_lanes) == 2 else 'historical' if historical_lanes else 'paired'
            phase_ratios = (historical_cli_help_phase_ratios(lanes)
                            if component == 'container' and fixture == 'cli-run-help'
                            and comparison == 'historical' else None)
            medians = {lane: statistics.median(r['seconds'] for r in rows)
                       for lane, rows in lanes.items()}
            ratio = medians['fork'] / medians['stock']
            stock_trials = {r['trial']: r for r in lanes['stock']}
            trial_ratios = [r['seconds'] / stock_trials[r['trial']]['seconds']
                            for r in lanes['fork'] if r['trial'] in stock_trials]
            worst_ratio = max(trial_ratios, default=ratio)
            if phase_ratios is not None:
                worst_ratio = max(phase_ratios.values())
            elif comparison == 'historical':
                # Other historical lanes retain the conservative extrema rule.
                worst_ratio = max(r['seconds'] for r in lanes['fork']) / min(r['seconds'] for r in lanes['stock'])
            completed = all(r['status'] == 0 for rows in lanes.values() for r in rows)
            passed = completed and worst_ratio < 10
            if not completed:
                ratio, worst_ratio = None, None
            entry = dict(component=component, fixture=fixture, **medians,
                         ratio=ratio, worst_trial_ratio=worst_ratio, passed=passed,
                         comparison=comparison, historical_lanes=historical_lanes)
            if phase_ratios is not None:
                entry['phase_ratios'] = phase_ratios
            matrix.append(entry)
            if phase_ratios is not None:
                case = ET.SubElement(suite, 'testcase', classname=component, name=fixture + '/historical-phases')
                properties = ET.SubElement(case, 'properties')
                for phase, value in phase_ratios.items():
                    ET.SubElement(properties, 'property', name=phase + '-ratio', value=f'{value:.9f}')
            elif worst_ratio is not None and worst_ratio >= 10:
                case = ET.SubElement(suite, 'testcase', classname=component, name=fixture + '/ratio')
            if worst_ratio is not None and worst_ratio >= 10:
                failing_phase = max(phase_ratios, key=phase_ratios.get) + ': ' if phase_ratios else ''
                ET.SubElement(case, 'failure', message=f'{failing_phase}{worst_ratio:.3f}x slowdown')
        ET.ElementTree(suite).write(self.evidence / 'timings.xml', encoding='unicode')
        (self.evidence / 'matrix.json').write_text(json.dumps(matrix, indent=2) + '\n')
        lines = ['# Fork versus Apple benchmark', '',
                 '| Component | Fixture | Apple seconds | Fork seconds | Fork/Apple | Pass |',
                 '| --- | --- | ---: | ---: | ---: | --- |']
        for row in matrix:
            comparison = f"{row['ratio']:.2f}x" if row['ratio'] is not None else 'Not qualified'
            lines.append(f"| {row['component']} | {row['fixture']} | {row['stock']:.3f} | {row['fork']:.3f} | {comparison} | {row['passed']} |")
        if any(row['fixture'].startswith('tls-') for row in matrix):
            lines += ['', 'TLS workloads use the same upstream performance source with optimized libraries, run directly without Bazel. Each process includes startup, one warmup and ten samples of 1,000 handshakes or 200,000 encrypted 512-byte writes. Ratios use monotonic process durations; the upstream wall-clock samples are retained only as diagnostics. Compatibility-test failures remain separate.']
        if any(row.get('historical') for row in rows):
            lines += ['', 'Historical lanes are checksum-bound retained measurements, not fresh passing assertions. Only candidate rows execute in this run. Except for Container CLI help, new-versus-historical timing gates compare the slowest candidate sample with the fastest reference sample.']
        for row in matrix:
            phases = row.get('phase_ratios')
            if phases is not None:
                lines += ['', 'Container CLI help keeps every original sample: first invocation (trial 0) compares with historical trial 0; repeated invocations (trials 1-10) use the conservative slowest candidate over fastest historical sample within that phase. These are historical phase comparisons, not contemporaneous pairs.',
                          f"First invocation: {phases['first-invocation']:.3f}x. Repeated invocations: {phases['repeated-invocation']:.3f}x. Gate: {row['worst_trial_ratio']:.3f}x (<10x required)."]
        (self.evidence / 'matrix.md').write_text('\n'.join(lines) + '\n')
        go_path = self.evidence / 'go-benchmarks.json'
        if go_path.exists():
            measurements = json.loads(go_path.read_text())
            go_matrix = []
            for fixture in sorted({r['fixture'] for r in measurements}):
                lanes = {lane: [r for r in measurements if r['fixture'] == fixture and r['lane'] == lane]
                         for lane in ['stock', 'fork']}
                if not all(lanes.values()):
                    go_matrix.append(dict(fixture=fixture, stock=None, fork=None,
                                          ratio=None, passed=False))
                    case = ET.SubElement(suite, 'testcase', classname='prefetch-throughput', name=fixture)
                    ET.SubElement(case, 'failure', message='Missing paired throughput measurement')
                    continue
                medians = {lane: statistics.median(r['ns_per_op'] for r in rows)
                           for lane, rows in lanes.items()}
                ratio = medians['fork'] / medians['stock']
                stock_trials = {r['trial']: r for r in lanes['stock']}
                worst_ratio = max(r['ns_per_op'] / stock_trials[r['trial']]['ns_per_op']
                                  for r in lanes['fork'] if r['trial'] in stock_trials)
                go_matrix.append(dict(fixture=fixture, **medians, ratio=ratio,
                                      worst_trial_ratio=worst_ratio, passed=worst_ratio < 10))
                historical = all(row.get('historical') for rows in lanes.values() for row in rows)
                go_matrix[-1].update(historical=historical)
                if not historical:
                    case = ET.SubElement(suite, 'testcase', classname='prefetch-throughput', name=fixture)
                if worst_ratio is not None and worst_ratio >= 10:
                    if historical:
                        case = ET.SubElement(suite, 'testcase', classname='historical-reference', name=fixture)
                    ET.SubElement(case, 'failure', message=f'{worst_ratio:.3f}x slowdown')
            (self.evidence / 'go-matrix.json').write_text(json.dumps(go_matrix, indent=2) + '\n')
            with (self.evidence / 'matrix.md').open('a') as stream:
                stream.write('\n## Prefetch operations (median ns/op)\n\n')
                stream.write('| Fixture | Apple | Fork | Fork/Apple |\n| --- | ---: | ---: | ---: |\n')
                for row in go_matrix:
                    if row['ratio'] is None:
                        stream.write(f"| {row['fixture']} | Missing pair | Missing pair | Failed |\n")
                        continue
                    stream.write(f"| {row['fixture']} | {row['stock']:.0f} | {row['fork']:.0f} | {row['ratio']:.2f}x |\n")
            ET.ElementTree(suite).write(self.evidence / 'timings.xml', encoding='unicode')

    def cli(self, lane: str) -> None:
        workspace = self.scratch / 'container' / lane / 'workspace'
        prefix = [str(BAZEL), '--output_user_root=' + str(STORAGE / 'paired-output')]
        execution_root = Path(output(prefix + ['info', 'execution_root'], workspace, self.env))
        files = output(prefix + ['cquery', '@swiftpkg_container//:container.rspm',
                       '--output=files'], workspace, self.env).splitlines()
        binaries = [execution_root / p for p in files if p.endswith('/container.rspm.__impl')]
        if len(binaries) != 1:
            raise RuntimeError(f'Expected one CLI binary, got {files}')
        binary = binaries[0]
        (self.evidence / f'container-{lane}-binary.json').write_text(json.dumps({
            'path': str(binary), 'sha256': digest(binary)}, indent=2) + '\n')
        failed = set()
        for trial in range(11):
            for name, arguments in [('cli-run-help', ['run', '--help']), ('cli-version', ['--version'])]:
                if name in failed:
                    continue
                row = self.run('container', lane, name, trial,
                               [str(binary), *arguments], workspace, 10)
                if row['status']:
                    failed.add(name)

    def builder(self, lanes=('stock', 'fork')) -> None:
        component = 'container-builder-shim'
        go = ['env', 'GOTOOLCHAIN=go1.25.9',
              'GOCACHE=' + str(STORAGE / 'paired-go-cache'),
              '/opt/homebrew/bin/go']
        linux = ['env', 'GOOS=linux', 'GOARCH=arm64', 'CGO_ENABLED=0', *go]
        build = ['build', '-p=6', '-tags=osusergo,netgo,static_build,seccomp',
                 '-ldflags=-w -s -extldflags=-static -X main.VERSION=benchmark',
                 '-o', '../container-builder-shim-linux', '.']
        benchmarks = ['BenchmarkDirectReaderAt', 'BenchmarkDirectReaderAtRandom',
                      'BenchmarkPrefetcherSequential', 'BenchmarkPrefetcherRandom']
        go_results = self.evidence / 'go-benchmarks.json'
        measurements = json.loads(go_results.read_text()) if go_results.exists() else []
        measurements = [row for row in measurements
                         if row.get('historical') and row.get('lane') not in lanes]
        goroot = Path(output(go + ['env', 'GOROOT']))
        (self.evidence / 'go-toolchain.json').write_text(json.dumps({
            'version': output(go + ['version']), 'root': str(goroot),
            'sha256': digest(goroot / 'bin/go'), 'linux_build_jobs': 6,
            'benchmarks': benchmarks, 'iterations_per_trial': 1024,
            'bytes_per_read': 4096}, indent=2) + '\n')
        for lane in lanes:
            workspace = self.scratch / component / lane / 'workspace'
            self.run(component, lane, 'toolchain', 0, go + ['version'], workspace)
            self.run(component, lane, 'prepare-build', 0,
                     go + ['test', '-c', '-o', str(workspace.parent / 'prefetch.test'), './pkg/prefetch'], workspace)
            self.run(component, lane, 'prepare-linux-build', 0, linux + build, workspace)
            binary = workspace.parent / 'container-builder-shim-linux'
            if binary.exists():
                (self.evidence / f'builder-{lane}-binary.json').write_text(json.dumps({
                    'path': str(binary), 'sha256': digest(binary),
                    'go_mod_sha256': digest(workspace / 'go.mod'),
                    'go_sum_sha256': digest(workspace / 'go.sum')}, indent=2) + '\n')
        failed_fixtures = set()
        for trial in range(3):
            trial_lanes = lanes if trial % 2 == 0 else list(reversed(lanes))
            for lane in trial_lanes:
                workspace = self.scratch / component / lane / 'workspace'
                self.run(component, lane, 'cached-linux-build', trial, linux + build, workspace)
                if (lane, 'prefetch-tests') not in failed_fixtures:
                    row = self.run(component, lane, 'prefetch-tests', trial,
                                   go + ['test', '-count=1', '-timeout=120s', './pkg/prefetch'], workspace, 150)
                    if row['status']:
                        failed_fixtures.add((lane, 'prefetch-tests'))
                for name in benchmarks:
                    if (lane, name) in failed_fixtures:
                        continue
                    row = self.run(component, lane, name, trial,
                                   [str(workspace.parent / 'prefetch.test'), '-test.run=^$',
                                    '-test.bench=^' + name + '$', '-test.benchtime=1024x',
                                    '-test.benchmem', '-test.count=1'], workspace, 60)
                    match = re.search(r'^' + name + r'-\d+\s+(\d+)\s+([\d.]+) ns/op',
                                      Path(row['log']).read_text(), re.MULTILINE)
                    if match and int(match.group(1)) == 1024 and row['status'] == 0:
                        measurements.append(dict(lane=lane, fixture=name, trial=trial,
                                                 iterations=1024, ns_per_op=float(match.group(2))))
                    elif row['status'] == 0:
                        row['status'] = 65
                    if row['status']:
                        failed_fixtures.add((lane, name))
        go_results.write_text(json.dumps(measurements, indent=2) + '\n')
        for lane in lanes:
            workspace = self.scratch / component / lane / 'workspace'
            originals = {}
            marker = uuid.uuid4().hex
            (self.evidence / f'{component}-{lane}-recompile-marker.txt').write_text(marker + '\n')
            try:
                paths = list(workspace.glob('*.go')) + list((workspace / 'pkg').rglob('*.go'))
                for path in paths:
                    if path.name.endswith('_test.go'):
                        continue
                    originals[path] = path.read_bytes()
                    path.write_bytes(originals[path] + f'\n// Paired component recompile {marker}.\n'.encode())
                self.run(component, lane, 'component-recompile', 0, linux + build, workspace)
            finally:
                for path, content in originals.items():
                    path.write_bytes(content)


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path, help='New internal-storage evidence directory')
    parser.add_argument('--scratch', required=True, type=Path, help='New disposable directory on enrolled SSD')
    parser.add_argument('--component', choices=list(PAIRS), action='append')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--use-prepared', action='store_true', help='Use previously prepared source fixtures')
    parser.add_argument('--reuse-reference', action='store_true',
                        help='Reuse published stock measurements and execute the changed fork components')
    parser.add_argument('--measure-all-candidates', action='store_true',
                        help='With --reuse-reference, freshly measure all five fork candidates against retained stock baselines')
    parser.add_argument('--phase', choices=['all', 'tests', 'recompile', 'tls'], default='all',
                        help='Run everything, tests/compilation, only compilation, or only optimized SSL workloads')
    args = parser.parse_args()
    if args.phase == 'tls' and args.component != ['swift-nio-ssl']:
        parser.error('--phase tls requires only --component swift-nio-ssl')
    if args.measure_all_candidates and not args.reuse_reference:
        parser.error('--measure-all-candidates requires --reuse-reference')
    if args.reuse_reference and (args.component or args.phase != 'all' or args.prepare_only):
        parser.error('--reuse-reference requires the complete component comparison')
    if args.measure_all_candidates and (args.component or args.phase != 'all' or args.prepare_only):
        parser.error('--measure-all-candidates requires the complete component comparison')
    args.evidence = args.evidence.resolve()
    args.scratch = args.scratch.resolve()
    # The active container checkpoint includes workflow and runtime fixes which
    # may not yet be on the fork's main branch. Never benchmark an older main.
    PAIRS['container'].update(repo=str(ROOT), fork=output(['git', 'rev-parse', 'HEAD'], ROOT))
    PAIRS['containerization']['fork'] = next(pin['state']['revision'] for pin in json.loads((ROOT / 'Package.resolved').read_text())['pins'] if pin['identity'] == 'containerization')
    if digest(BAZEL) != BAZEL_SHA:
        raise SystemExit('Bazel checksum mismatch')
    reference = None
    reference_admission = None
    if args.reuse_reference:
        from benchmark_reference import fetch
        from component_reference import validate_inputs
        reference = fetch()
        reference_admission = {}
        changed = validate_inputs(reference, PAIRS, ROOT, BAZEL_SHA, reference_admission)
    # Reuse the established enrollment preflight before creating source snapshots.
    subprocess.run([str(ROOT / 'Tools/bazel/run.sh'), 'info', 'release'], check=True,
                   stdout=subprocess.DEVNULL)
    if not args.scratch.resolve().is_relative_to(STORAGE):
        raise SystemExit('Scratch must be inside the enrolled container-only storage')
    args.evidence.mkdir(parents=True, exist_ok=False)
    args.scratch.mkdir(parents=True, exist_ok=args.use_prepared)
    components = args.component or list(PAIRS)
    measured_components = (list(PAIRS) if args.measure_all_candidates else changed) if reference is not None else components
    lanes = ['fork'] if reference is not None else ['stock', 'fork']
    metadata = dict(phase=args.phase, components=components, pairs=PAIRS, third_party_lock=digest(ROOT / 'Package.resolved'),
                    measured_components=measured_components, historical_reference=reference is not None,
                    candidate_measurement_scope=('all' if args.measure_all_candidates else 'changed'),
                    component_reference_admission=reference_admission,
                    harness_revision=output(['git', 'rev-parse', 'HEAD'], ROOT),
                    macos=output(['sw_vers']), swift=output(['xcrun', 'swift', '--version']),
                    hardware=output(['sysctl', '-n', 'machdep.cpu.brand_string', 'hw.memsize', 'hw.ncpu']),
                    bazel_sha256=BAZEL_SHA, started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    (args.evidence / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    shutil.copy2(__file__, args.evidence / 'fork_benchmark.py')
    runner = Runner(args.evidence, args.scratch)
    if reference is not None:
        from benchmark_reference import retain
        from component_reference import retained_go, retained_rows
        retain(args.evidence, reference)
        runner.reference_rows, differences = retained_rows(reference, measured_components)
        (args.evidence / 'historical-differences.json').write_text(json.dumps(differences, indent=2) + '\n')
        (args.evidence / 'go-benchmarks.json').write_text(json.dumps(retained_go(reference), indent=2) + '\n')
    for component in measured_components:
        for lane in lanes:
            if args.use_prepared:
                base = args.scratch / component / lane
                for name, expected in json.loads((base / 'inputs.json').read_text()).items():
                    if digest(base / name) != expected:
                        raise SystemExit(f'Prepared input changed: {base / name}')
            prepare(component, lane, args.scratch)
            shutil.copy2(args.scratch / component / lane / 'inputs.json',
                         args.evidence / f'{component}-{lane}-inputs.json')
    if args.prepare_only:
        return
    try:
        for component in measured_components:
            if component == 'container-builder-shim':
                runner.builder(lanes)
                continue
            with runner.bazel_session(component, lanes):
                if args.phase == 'tls':
                    runner.tls(lanes)
                    continue
                pair = PAIRS[component]
                repo = '@swiftpkg_' + component.replace('-', '_') + '//:'
                tests = [repo + t + '.rspm' for t in pair['tests']]
                good = True
                for lane in lanes:
                    row = runner.bazel(component, lane, 'prepare-build', 0, 'build', ['//:component', *tests])
                    good = good and row['status'] == 0
                if not good:
                    continue
                if component == 'container' and args.phase == 'all':
                    for lane in lanes:
                        runner.cli(lane)
                failed_fixtures = set()
                for trial in range(0 if args.phase == 'recompile' else 3):
                    for lane in (lanes if trial % 2 == 0 else list(reversed(lanes))):
                        runner.bazel(component, lane, 'cached-build', trial, 'build', ['//:component'])
                        for name, target in zip(pair['tests'], tests):
                            if (lane, name) in failed_fixtures:
                                continue
                            row = runner.bazel(component, lane, name, trial, 'test', [target],
                                               ['--nocache_test_results', '--test_timeout=120', '--local_test_jobs=1'])
                            if row['status']:
                                failed_fixtures.add((lane, name))
                if component == 'swift-nio-ssl' and args.phase != 'recompile':
                    runner.tls(lanes)
                # No-op comments force the component's Swift source compilation.
                # Dependency sources are untouched; report first builds separately.
                for lane in lanes:
                    base = args.scratch / component / lane
                    source = base / ('workspace' if component == 'container' else 'component')
                    originals = {}
                    marker = uuid.uuid4().hex
                    (args.evidence / f'{component}-{lane}-recompile-marker.txt').write_text(marker + '\n')
                    try:
                        for path in (source / 'Sources').rglob('*.swift'):
                            originals[path] = path.read_bytes()
                            path.write_bytes(originals[path] + f'\n// Paired component recompile {marker}.\n'.encode())
                        runner.bazel(component, lane, 'component-recompile', 0, 'build', ['//:component'])
                    finally:
                        for path, content in originals.items():
                            path.write_bytes(content)
    finally:
        runner.report()
    if reference is not None:
        from component_reference import require_candidate_rows
        require_candidate_rows(runner.rows, measured_components, PAIRS)
        final_admission = {}
        validate_inputs(reference, PAIRS, ROOT, digest(BAZEL), final_admission)
        if final_admission != reference_admission:
            raise RuntimeError('Component reference admission changed during the run')
    matrix = json.loads((args.evidence / 'matrix.json').read_text())
    if (args.evidence / 'go-matrix.json').exists():
        matrix += json.loads((args.evidence / 'go-matrix.json').read_text())
    from comparison_review import review
    disposition = review(args.evidence)
    if not disposition['completed']:
        raise SystemExit(1)
    if disposition['compatible'] is False:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
