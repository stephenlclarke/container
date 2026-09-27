#!/usr/bin/env python3
"""Run the runtime workloads against an explicitly selected, running Docker engine."""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import uuid

from fork_benchmark import Runner
from runtime_benchmark import ALPINE, FIXTURES, INSTALLS


def benchmark(evidence: Path, context: str, trials: int) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, evidence)
    docker = ['docker', '--context', context]
    prefix = 'cf-perf-' + uuid.uuid4().hex[:12]
    warm, tag = prefix + '-warm', prefix + ':result'
    failures = []

    def command(fixture, trial, args, expected=None):
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
    except Exception as error:
        failures.append(str(error))
    finally:
        # Only unique resources created by this invocation may be removed.
        for kind, name in [('container', warm), ('image', tag)]:
            present = subprocess.run(docker + [kind, 'inspect', name], capture_output=True)
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context', required=True)
    parser.add_argument('--trials', type=int, default=7)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if args.trials < 1:
        parser.error('--trials must be positive')
    benchmark(args.evidence, args.context, args.trials)
