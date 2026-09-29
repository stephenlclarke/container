#!/usr/bin/env python3
"""Run the runtime workloads against an explicitly selected, running Docker engine."""

import argparse
import ast
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import uuid

from fork_benchmark import ROOT, Runner, install_signal_handlers
from runtime_benchmark import ALPINE, FIXTURES, INSTALLS


def historical_samples(reference: dict, context: str, trials: int) -> tuple[list[dict], dict]:
    """A historical lane has the original complete protocol, never a new capture."""
    from benchmark_reference import ARCHIVE_SHA256
    protocol = reference['protocol']
    expected = {'dockerContext': context, 'dockerTrials': trials, 'dockerImage': ALPINE,
                'dockerArchitecture': 'linux/arm64', 'dockerServiceCPUs': 1,
                'dockerServiceMemory': '512m'}
    if any(protocol.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Historical Docker workload protocol differs')
    rows = reference['docker']['raw']
    if (len(rows) != 72 or len({(r['fixture'], r['trial']) for r in rows}) != 72
            or any(r['lane'] != 'docker' or r['status'] != 0 or not math.isfinite(r['seconds'])
                   or r['seconds'] <= 0 for r in rows)):
        raise RuntimeError('Historical Docker raw outcomes are incomplete or failed')
    medians = {}
    for fixture in FIXTURES:
        samples = [row for row in rows if row['fixture'] == fixture]
        if len(samples) != trials or {r['trial'] for r in samples} != set(range(1, trials + 1)):
            raise RuntimeError('Historical Docker fixture samples are incomplete: ' + fixture)
        medians[fixture] = statistics.median(row['seconds'] for row in samples)
    if medians != reference['docker']['medians']:
        raise RuntimeError('Historical Docker medians differ from raw measurements')
    return [dict(row, historical=True, reference_archive_sha256=ARCHIVE_SHA256) for row in rows], medians


def engine_identity(version: dict, info: dict, compose_version: str) -> dict:
    return {'architecture': info['Architecture'], 'cgroupVersion': info['CgroupVersion'],
            'clientVersion': version['Client']['Version'], 'serverVersion': version['Server']['Version'],
            'composePluginVersion': compose_version.lstrip('v'), 'cpus': info['NCPU'],
            'memoryBytes': info['MemTotal'], 'kernelVersion': info['KernelVersion'],
            'operatingSystem': info['OperatingSystem'], 'storageDriver': info['Driver']}


def reuse(evidence: Path, context: str, trials: int) -> None:
    """Validate the selected engine read-only and retain the published Docker lane."""
    from benchmark_reference import canonical_ast, fetch, retain, validate_contract, RUNNER_CONTRACT
    from component_reference import original, command
    reference = fetch()
    rows, medians = historical_samples(reference, context, trials)
    old = ast.parse(original(ROOT, 'Tools/bazel/docker_benchmark.py').decode())
    current = ast.parse(Path(__file__).read_text())
    definition = lambda tree: next(canonical_ast(node) for node in tree.body
                                   if isinstance(node, ast.FunctionDef) and node.name == 'benchmark')
    if definition(old) != definition(current):
        raise RuntimeError('Docker workload or timing boundary differs from the historical reference')
    validate_contract(ROOT / 'Tools/bazel/fork_benchmark.py', RUNNER_CONTRACT)
    host = reference['phaseHosts']['runtimeBenchmark']
    for key, arguments in {'model': ['sysctl', '-n', 'hw.model'], 'memoryBytes': ['sysctl', '-n', 'hw.memsize'],
                           'macOSVersion': ['sw_vers', '-productVersion'], 'macOSBuild': ['sw_vers', '-buildVersion'],
                           'architecture': ['uname', '-m']}.items():
        if command(arguments, ROOT) != str(host[key]):
            raise RuntimeError('Historical Docker host differs: ' + key)
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, evidence)
    observed = []
    for fixture, arguments in [('engine', ['version', '--format', '{{json .}}']),
                               ('engine-info', ['info', '--format', '{{json .}}']),
                               ('compose-version', ['compose', 'version', '--short'])]:
        row = runner.run('reference-admission', 'docker', fixture, 0,
                         ['docker', '--context', context, *arguments], evidence, timeout=30)
        if row['status']:
            raise RuntimeError('Cannot verify selected historical Docker engine: ' + fixture)
        observed.append(Path(row['log']).read_text().strip())
    actual = engine_identity(json.loads(observed[0]), json.loads(observed[1]), observed[2])
    expected = {key: value for key, value in reference['protocol']['dockerEngine'].items() if key != 'sourceLogSHA256'}
    if actual != expected:
        raise RuntimeError('Selected Docker engine differs from the historical reference')
    retain(evidence, reference)
    (evidence / 'engine-admission.json').write_text(json.dumps({'current': actual, 'historical': expected,
                                                             'checks': runner.rows}, indent=2) + '\n')
    (evidence / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    (evidence / 'acceptance.json').write_text(json.dumps({
        'passed': True, 'historical': True, 'workloads_executed': False,
        'assertions_replayed': False, 'failures': [], 'medians': medians,
        'interpretation': 'Published measurements reused after read-only host/engine admission; no Docker workload rerun.',
    }, indent=2) + '\n')


def benchmark(evidence: Path, context: str, trials: int) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, evidence)
    docker = ['docker', '--context', context]
    prefix = 'cf-perf-' + uuid.uuid4().hex[:12]
    warm, tag = prefix + '-warm', prefix + ':result'
    failures = []

    def command(fixture, trial, args, expected=None):
        if args[0] == 'run':
            ownership = ['--label', 'io.container-only.owner=' + prefix]
            if '--name' not in args:
                ownership += ['--name', prefix + '-' + fixture + '-' + str(trial)]
            args = [args[0], *ownership, *args[1:]]
        row = runner.run('runtime-stack', 'docker', fixture, trial, docker + args, evidence)
        if expected is not None and expected not in Path(row['log']).read_text():
            row['status'] = row['status'] or 1
        if row['status']:
            raise RuntimeError(f"{fixture} failed: {row['log']}")

    try:
        command('engine', 0, ['version', '--format', '{{json .}}'])
        command('engine-info', 0, ['info', '--format', '{{json .}}'])
        active = subprocess.check_output(docker + ['ps', '-q'], text=True).strip()
        if active:
            raise RuntimeError('Active Docker workloads would contaminate the measurement')
        (evidence / 'host.json').write_text(json.dumps({
            'context': context, 'trials': trials, 'image': ALPINE,
            'architecture': 'linux/arm64', 'cpus': 1, 'memory': '512m',
            'isolation': 'fresh container in an already running shared Colima VM',
            'apple_isolation': 'fresh dedicated VM per container',
            'builder': 'Docker default BuildKit in the shared VM; see engine-info for VM resources',
            'source_archive': str(INSTALLS / 'assets/alpine.tar'),
            'resource_prefix': prefix,
        }, indent=2) + '\n')
        command('setup-images', 0, ['image', 'load', '--input', str(INSTALLS / 'assets/alpine.tar')])
        # A loaded OCI archive may not retain the registry digest alias.
        command('setup-pull', 0, ['pull', '--platform', 'linux/arm64', ALPINE])
        resources = ['--platform', 'linux/arm64', '--cpus', '1', '--memory', '512m', '--network', 'none']
        command('setup-vm', 0, ['run', *resources, '--rm', ALPINE, 'echo', 'runtime-ready'], 'runtime-ready')
        command('setup-warm', 0, ['run', *resources, '--detach', '--name', warm, ALPINE, 'sleep', '3600'])
        expected_hash = hashlib.sha256(bytes(128 * 1024 * 1024)).hexdigest()
        for trial in range(1, trials + 1):
            command('start-exit', trial, ['run', *resources, '--rm', ALPINE, 'true'])
            command('warm-exec', trial, ['exec', warm, 'echo', 'exec-ok'], 'exec-ok')
            command('sha256-128m', trial, ['exec', warm, 'sh', '-ec',
                    'dd if=/dev/zero bs=1048576 count=128 2>/dev/null | sha256sum'], expected_hash)
            command('write-sync-64m', trial, ['exec', warm, 'sh', '-ec',
                    'dd if=/dev/zero of=/tmp/bench-data bs=1048576 count=64 2>/dev/null; sync; wc -c </tmp/bench-data; rm /tmp/bench-data'], '67108864')
            archive = evidence / 'alpine-save.tar'
            command('image-save', trial, ['image', 'save', '--output', str(archive), ALPINE])
            archive.unlink()
            command('image-load-warm', trial, ['image', 'load', '--input', str(INSTALLS / 'assets/alpine.tar')])
        build_context = evidence / 'context'
        build_context.mkdir()
        payload = b'container runtime benchmark\n' * 4096
        (build_context / 'payload.txt').write_bytes(payload)
        (build_context / 'Dockerfile').write_text(
            f'FROM {ALPINE}\nCOPY payload.txt /payload.txt\nRUN sha256sum /payload.txt > /result.txt\n')
        build = ['build', '--platform', 'linux/arm64', '--progress', 'plain', '--tag', tag, str(build_context)]
        command('setup-build', 0, build)
        for trial in range(1, trials + 1):
            command('build-no-cache', trial, [build[0], '--no-cache', *build[1:]])
            command('build-cached', trial, build)
            command('validate-build', trial, ['run', *resources, '--rm', tag, 'cat', '/result.txt'],
                    hashlib.sha256(payload).hexdigest())
    except BaseException as error:
        failures.append(str(error))
        if not isinstance(error, Exception):
            raise
    finally:
        # Short-lived `run --rm` containers can survive a killed Docker client.
        # The invocation label also covers those without touching other work.
        try:
            owned = subprocess.check_output(docker + ['ps', '-aq', '--filter', 'label=io.container-only.owner=' + prefix],
                                            text=True, timeout=20).split()
            for container in owned:
                command('cleanup-transient', 0, ['container', 'rm', '--force', container])
        except (OSError, subprocess.SubprocessError, RuntimeError) as error:
            failures.append('Owned Docker container cleanup failed: ' + str(error))
        # Only unique resources created by this invocation may be removed.
        for kind, name in [('container', warm), ('image', tag)]:
            present = subprocess.run(docker + [kind, 'inspect', name], capture_output=True, timeout=20)
            if present.returncode == 0:
                try:
                    command('cleanup-' + kind, 0, [kind, 'rm', '--force', name])
                except Exception as error:
                    failures.append(str(error))
        (evidence / 'results.json').write_text(json.dumps(runner.rows, indent=2) + '\n')
        medians = {}
        for fixture in FIXTURES:
            rows = [r for r in runner.rows if r['fixture'] == fixture]
            if len(rows) != trials or any(r['status'] for r in rows):
                failures.append(f'Incomplete or failed workload: {fixture}')
            elif rows:
                medians[fixture] = statistics.median(r['seconds'] for r in rows)
        (evidence / 'acceptance.json').write_text(json.dumps({
            'passed': not failures, 'failures': failures, 'medians': medians,
        }, indent=2) + '\n')
    if failures:
        raise RuntimeError('; '.join(failures))


if __name__ == '__main__':
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context', required=True)
    parser.add_argument('--trials', type=int, default=7)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--reuse-reference', action='store_true', help='Reuse pinned historical measurements after read-only engine admission')
    args = parser.parse_args()
    if args.trials < 1:
        parser.error('--trials must be positive')
    (reuse if args.reuse_reference else benchmark)(args.evidence, args.context, args.trials)
