#!/usr/bin/env python3
"""Benchmark matching Apple/fork sources in disposable, pinned Bazel fixtures.

Usage: python3 Tools/bazel/fork_benchmark.py --help
Source checkouts and installed container services are never modified.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import tarfile
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
STORAGE = Path('/Volumes/SSD/cf/container-only')
BAZEL = Path('/Volumes/SSD/cf/bazel/bootstrap/bazel-8.8.0-darwin-arm64')
BAZEL_SHA = 'f0ac192aba2ccaa373cdfd527d4c407cc492c1296a2f11a4b67563e4d5aa9acb'
PAIRS = {
    'containerization': {
        'repo': '/Users/sclarke/github/containerization',
        'stock': 'bc994b88df46207fad7775b0eabc51947e315881',
        'fork': 'f58053cc72dc5dfae419bfc1667220b35b61a1a1',
        'products': ['ContainerizationExtras', 'ContainerizationArchive',
                     'ContainerizationEXT4', 'ContainerizationOCI', 'Containerization'],
        'tests': ['ContainerizationExtrasTests', 'ContainerizationArchiveTests',
                  'ContainerizationEXT4Tests', 'ContainerizationOCITests'],
    },
    'container': {
        'repo': '/Users/sclarke/github/container',
        'stock': '4a7d8615241b8ddecfd3bf225cd7c44f4b2ccf7c',
        'fork': '193be5b77294d79c4120aa486603840508ded794',
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


def output(args: list[str], cwd: Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive(repo: str | Path, revision: str, dest: Path, paths: tuple | list = ()) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(['git', '-C', str(repo), 'archive', revision, *paths],
                            stdout=subprocess.PIPE)
    with tarfile.open(fileobj=proc.stdout, mode='r|') as tar:
        tar.extractall(dest, filter='data')
    if proc.wait():
        raise RuntimeError(f'git archive failed: {repo} {revision}')


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


class Runner:
    def __init__(self, evidence: Path, scratch: Path) -> None:
        self.evidence = evidence
        self.scratch = scratch
        self.rows: list[dict] = []
        self.env = dict(os.environ, TMPDIR=str(STORAGE / 'tmp') + '/', CI='1')

    def run(self, component: str, lane: str, fixture: str, trial: int,
            args: list[str], cwd: Path, timeout: int = 600) -> dict:
        number = len(self.rows)
        stem = f'{number:03}-{component}-{lane}-{fixture}-{trial}'
        log = self.evidence / (stem + '.log')
        print(stem, flush=True)
        start = time.monotonic_ns()
        interrupted = False
        with log.open('w') as stream:
            try:
                result = subprocess.run(args, cwd=cwd, env=self.env, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=timeout)
                status = result.returncode
            except subprocess.TimeoutExpired:
                status = 124
            except KeyboardInterrupt:
                status = 130
                interrupted = True
        elapsed = (time.monotonic_ns() - start) / 1e9
        row = dict(component=component, lane=lane, fixture=fixture, trial=trial,
                   seconds=elapsed, status=status, command=[str(a) for a in args], log=str(log))
        self.rows.append(row)
        (self.evidence / 'results.json').write_text(json.dumps(self.rows, indent=2) + '\n')
        print(f'  {elapsed:.3f}s status={status}', flush=True)
        if status:
            print(log.read_text()[-6000:], flush=True)
        if interrupted:
            raise KeyboardInterrupt
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

    def report(self) -> None:
        (self.evidence / 'results.json').write_text(json.dumps(self.rows, indent=2) + '\n')
        matrix = []
        fixtures = sorted({(r['component'], r['fixture']) for r in self.rows
                           if r['fixture'] not in {'prepare-build', 'prepare-linux-build', 'toolchain'}})
        suite = ET.Element('testsuite', name='fork-vs-apple')
        for row in self.rows:
            case = ET.SubElement(suite, 'testcase', classname=row['component'],
                                 name=f"{row['lane']}/{row['fixture']}/{row['trial']}",
                                 time=str(row['seconds']))
            if row['status']:
                ET.SubElement(case, 'failure', message=f"exit {row['status']}").text = row['log']
        for component, fixture in fixtures:
            lanes = {lane: [r for r in self.rows if r['component'] == component and
                            r['fixture'] == fixture and r['lane'] == lane]
                     for lane in ['stock', 'fork']}
            if not all(lanes.values()):
                continue
            medians = {lane: statistics.median(r['seconds'] for r in rows)
                       for lane, rows in lanes.items()}
            ratio = medians['fork'] / medians['stock']
            stock_trials = {r['trial']: r for r in lanes['stock']}
            trial_ratios = [r['seconds'] / stock_trials[r['trial']]['seconds']
                            for r in lanes['fork'] if r['trial'] in stock_trials]
            worst_ratio = max(trial_ratios, default=ratio)
            passed = all(r['status'] == 0 for rows in lanes.values() for r in rows) and worst_ratio < 10
            matrix.append(dict(component=component, fixture=fixture, **medians,
                               ratio=ratio, worst_trial_ratio=worst_ratio, passed=passed))
            if worst_ratio >= 10:
                case = ET.SubElement(suite, 'testcase', classname=component, name=fixture + '/ratio')
                ET.SubElement(case, 'failure', message=f'{worst_ratio:.3f}x slowdown')
        ET.ElementTree(suite).write(self.evidence / 'timings.xml', encoding='unicode')
        (self.evidence / 'matrix.json').write_text(json.dumps(matrix, indent=2) + '\n')
        lines = ['# Fork versus Apple benchmark', '',
                 '| Component | Fixture | Apple seconds | Fork seconds | Fork/Apple | Pass |',
                 '| --- | --- | ---: | ---: | ---: | --- |']
        lines.extend(f"| {r['component']} | {r['fixture']} | {r['stock']:.3f} | {r['fork']:.3f} | {r['ratio']:.2f}x | {r['passed']} |" for r in matrix)
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
                case = ET.SubElement(suite, 'testcase', classname='prefetch-throughput', name=fixture)
                if worst_ratio >= 10:
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
        execution_root = Path(subprocess.check_output(prefix + ['info', 'execution_root'],
                             cwd=workspace, env=self.env, text=True).strip())
        files = subprocess.check_output(prefix + ['cquery', '@swiftpkg_container//:container.rspm',
                        '--output=files'], cwd=workspace, env=self.env, text=True).splitlines()
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

    def builder(self) -> None:
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
        measurements = []
        goroot = Path(output(go + ['env', 'GOROOT']))
        (self.evidence / 'go-toolchain.json').write_text(json.dumps({
            'version': output(go + ['version']), 'root': str(goroot),
            'sha256': digest(goroot / 'bin/go'), 'linux_build_jobs': 6,
            'benchmarks': benchmarks, 'iterations_per_trial': 1024,
            'bytes_per_read': 4096}, indent=2) + '\n')
        for lane in ['stock', 'fork']:
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
            for lane in (['stock', 'fork'] if trial % 2 == 0 else ['fork', 'stock']):
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
        (self.evidence / 'go-benchmarks.json').write_text(json.dumps(measurements, indent=2) + '\n')
        for lane in ['stock', 'fork']:
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path, help='New internal-storage evidence directory')
    parser.add_argument('--scratch', required=True, type=Path, help='New disposable directory on enrolled SSD')
    parser.add_argument('--component', choices=list(PAIRS), action='append')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--use-prepared', action='store_true', help='Use previously prepared source fixtures')
    parser.add_argument('--phase', choices=['all', 'tests', 'recompile'], default='all',
                        help='Run everything, tests/compilation, or only component compilation')
    args = parser.parse_args()
    args.evidence = args.evidence.resolve()
    args.scratch = args.scratch.resolve()
    if digest(BAZEL) != BAZEL_SHA:
        raise SystemExit('Bazel checksum mismatch')
    # Reuse the established enrollment preflight before creating source snapshots.
    subprocess.run([str(ROOT / 'Tools/bazel/run.sh'), 'info', 'release'], check=True,
                   stdout=subprocess.DEVNULL)
    if not args.scratch.resolve().is_relative_to(STORAGE):
        raise SystemExit('Scratch must be inside the enrolled container-only storage')
    args.evidence.mkdir(parents=True, exist_ok=False)
    args.scratch.mkdir(parents=True, exist_ok=args.use_prepared)
    components = args.component or list(PAIRS)
    metadata = dict(pairs=PAIRS, third_party_lock=digest(ROOT / 'Package.resolved'),
                    harness_revision=output(['git', 'rev-parse', 'HEAD'], ROOT),
                    macos=output(['sw_vers']), swift=output(['xcrun', 'swift', '--version']),
                    hardware=output(['sysctl', '-n', 'machdep.cpu.brand_string', 'hw.memsize', 'hw.ncpu']),
                    bazel_sha256=BAZEL_SHA, started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    (args.evidence / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    shutil.copy2(__file__, args.evidence / 'fork_benchmark.py')
    runner = Runner(args.evidence, args.scratch)
    for component in components:
        for lane in ['stock', 'fork']:
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
        for component in components:
            if component == 'container-builder-shim':
                runner.builder()
                continue
            pair = PAIRS[component]
            repo = '@swiftpkg_' + component.replace('-', '_') + '//:'
            tests = [repo + t + '.rspm' for t in pair['tests']]
            good = True
            for lane in ['stock', 'fork']:
                row = runner.bazel(component, lane, 'prepare-build', 0, 'build', ['//:component', *tests])
                good = good and row['status'] == 0
            if not good:
                continue
            if component == 'container' and args.phase == 'all':
                for lane in ['stock', 'fork']:
                    runner.cli(lane)
            failed_fixtures = set()
            for trial in range(0 if args.phase == 'recompile' else 3):
                for lane in (['stock', 'fork'] if trial % 2 == 0 else ['fork', 'stock']):
                    runner.bazel(component, lane, 'cached-build', trial, 'build', ['//:component'])
                    for name, target in zip(pair['tests'], tests):
                        if (lane, name) in failed_fixtures:
                            continue
                        row = runner.bazel(component, lane, name, trial, 'test', [target],
                                           ['--nocache_test_results', '--test_timeout=120', '--local_test_jobs=1'])
                        if row['status']:
                            failed_fixtures.add((lane, name))
            # No-op comments force the component's Swift source compilation.
            # Dependency sources are untouched; report first builds separately.
            for lane in ['stock', 'fork']:
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
            for lane in ['stock', 'fork']:
                subprocess.run([str(BAZEL), '--output_user_root=' + str(STORAGE / 'paired-output'),
                                'shutdown'], cwd=args.scratch / component / lane / 'workspace',
                               check=True, stdout=subprocess.DEVNULL)
    finally:
        runner.report()
    matrix = json.loads((args.evidence / 'matrix.json').read_text())
    if (args.evidence / 'go-matrix.json').exists():
        matrix += json.loads((args.evidence / 'go-matrix.json').read_text())
    if any(row['status'] for row in runner.rows) or any(not row['passed'] for row in matrix):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
