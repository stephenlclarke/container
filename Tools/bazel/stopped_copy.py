"""Exercise stopped-copy through the signed CLI against a retained Docker oracle."""

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import stat
import sys
import time
import uuid
import xml.etree.ElementTree as ET


def workload_log_payloads(files: dict) -> dict:
    """Compare actual log records independently of asynchronous create metadata."""
    return {name: row for name, row in files.items()
            if row['size'] > 0 and (Path(name).name.startswith(('stdio.log', 'stdio.jsonl'))
                                   or name.startswith('logging-v2/json-file/'))}


def timing_pairs(operations: list[dict], reference: dict) -> list[dict]:
    """Pair only identical copy fixtures, including their full command overhead."""
    references = {}
    for row in reference['operations']:
        if row['fixture'].startswith('copy-'):
            if row['fixture'] in references or row['status'] != 0:
                raise ValueError('Ambiguous or failed Docker copy reference')
            references[row['fixture']] = row
    pairs = []
    seen = set()
    for row in operations:
        if row['fixture'] not in references:
            continue
        if row['fixture'] in seen:
            raise ValueError('Duplicate candidate copy fixture')
        seen.add(row['fixture'])
        old = references[row['fixture']]
        for sample in (old, row):
            if (type(sample['seconds']) not in (int, float)
                    or not math.isfinite(sample['seconds']) or sample['seconds'] <= 0):
                raise ValueError('Invalid fixture duration')
        ratio = row['seconds'] / old['seconds']
        pairs.append({'fixture': row['fixture'], 'dockerSeconds': old['seconds'],
                      'candidateSeconds': row['seconds'], 'ratio': ratio,
                      'passed': row['status'] == 0 and ratio < 10,
                      'method': 'Retained single Docker semantic-oracle sample; diagnostic, not causal performance evidence'})
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--oracle', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.source / 'Tools/bazel'))
    from fork_benchmark import digest, install_signal_handlers
    from runtime_benchmark import ALPINE, INSTALLS, STATE, RuntimeRunner, environment, reset_state, start_lane, stop_owned
    from runtime_integration import verify_prepared

    install_signal_handlers()
    oracle = json.loads((args.oracle / 'acceptance.json').read_text())
    if (oracle.get('passed') is not True or oracle.get('image') != ALPINE
            or digest(args.oracle.parent / 'docker_oracle.py') != oracle['oracleSHA256']):
        raise RuntimeError('Docker oracle failed authentication')
    for row in oracle['operations']:
        if digest(Path(row['log'])) != row['logSHA256']:
            raise RuntimeError('Docker oracle log changed')
    verify_prepared(args.prepared)
    evidence = args.evidence
    evidence.mkdir(mode=0o700, exist_ok=False)
    for name in ('source-inputs.json', 'fork-fingerprint.json', 'guest-artifact.json', 'builder-artifact.json', 'compiled-consumer.json'):
        shutil.copy2(args.prepared / name, evidence / name)
    runner = RuntimeRunner(evidence, STATE)
    identifier = uuid.uuid4().hex[:12]
    created, exited = 'copy-created-' + identifier, 'copy-exited-' + identifier
    owned = []
    result = {'passed': False, 'semanticPassed': False, 'failures': [], 'cases': [],
              'source': json.loads((evidence / 'source-inputs.json').read_text())['fork'],
              'baselineRebuiltOrRerun': False, 'oracleSHA256': digest(args.oracle / 'acceptance.json')}

    def command(label: str, arguments: list[str], allowed=(0,), timeout=120) -> dict:
        runner.env = environment('fork')
        row = runner.run('stopped-copy', 'fork', label, 0,
                         [str(INSTALLS / 'fork/install/bin/container'), *arguments], args.source, timeout=timeout)
        runner.report()
        if row['status'] not in allowed:
            raise RuntimeError(label + ' failed: ' + row['log'])
        return row

    def snapshot(name: str, label: str) -> dict:
        value = json.loads(Path(command(label, ['inspect', name])['log']).read_text())
        if len(value) != 1 or value[0]['id'] != name:
            raise RuntimeError('Ambiguous container inspection: ' + label)
        return value[0]

    def unchanged(name: str, before: dict, label: str) -> None:
        if snapshot(name, label) != before:
            raise RuntimeError('Copy changed container inspection: ' + label)

    def workload_logs(name: str) -> dict:
        bundle = STATE / 'fork/app/containers' / name
        files = [path for path in bundle.rglob('*') if path.is_file()
                 and (path.name.startswith(('stdio.log', 'stdio.jsonl'))
                      or path.relative_to(bundle).parts[0] == 'logging-v2')]
        if any(path.is_symlink() for path in files):
            raise RuntimeError('Unexpected symlink in owned workload logs')
        return {str(path.relative_to(bundle)): {'size': path.stat().st_size, 'sha256': digest(path)}
                for path in sorted(files)}

    def unchanged_logs(name: str, before: dict, label: str) -> None:
        after = workload_logs(name)
        result.setdefault('workloadLogs', []).append({'fixture': label, 'before': before, 'after': after})
        if after != before:
            raise RuntimeError('Copy changed workload logs: ' + label)

    def no_workload_events(name: str, since: float, label: str) -> None:
        row = command(label, ['events', '--since', str(since), '--until', str(time.time())])
        events = [json.loads(line) for line in Path(row['log']).read_text().splitlines() if line.strip()]
        unexpected = [event for event in events if event.get('id') == name]
        if unexpected:
            raise RuntimeError('Copy emitted unexpected lifecycle events: ' + json.dumps(unexpected))

    def case(label: str, started: float) -> None:
        result['cases'].append({'fixture': label, 'passed': True, 'seconds': time.monotonic() - started})

    resources = ['--cpus', '1', '--memory', '512m', '--network', 'none']
    with (INSTALLS / 'benchmark.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            stop_owned('fork')
            fingerprint = json.loads((evidence / 'fork-fingerprint.json').read_text())
            if reset_state('fork', fingerprint['init_image'], fingerprint['builder_image']) != fingerprint['kernel_sha256']:
                raise RuntimeError('Kernel fingerprint changed')
            start_lane(runner, 'fork')
            payload = evidence / 'payload'
            payload.write_bytes(b'created-and-stopped-copy\n' * 17)
            payload.chmod(0o640)
            workload = 'test -f /tmp/payload; cp /tmp/payload /tmp/persisted; printf executed > /tmp/workload-executed'
            owned.append(created)
            create_to_copy_started = time.monotonic()
            command('create-never-started', ['create', *resources, '--name', created, ALPINE, 'sh', '-ec', workload])
            before = snapshot(created, 'created-before')
            if before['status']['state'] != 'stopped' or before['status'].get('startedDate') is not None:
                raise RuntimeError('Created container is not never-started')
            started, since = time.monotonic(), time.time()
            logs = workload_logs(created)
            command('copy-into-created', ['cp', str(payload), created + ':/tmp/payload'])
            result['createdThroughFirstCopySeconds'] = time.monotonic() - create_to_copy_started
            after_first_copy = workload_logs(created)
            result['createdFirstCopyLogs'] = {
                'before': logs, 'after': after_first_copy,
                'scope': 'Default CLI create may initialize logging metadata asynchronously; '
                         'first-copy timing includes any wait for that work. Actual log records must remain unchanged. '
                         'Isolated cold/prewarmed integration fixtures prove complete log-bundle immutability.'}
            if workload_log_payloads(after_first_copy) != workload_log_payloads(logs):
                raise RuntimeError('Created copy changed workload log records')
            # The first copy has crossed the per-container lifecycle fence, so
            # create-time prewarming cannot race the subsequent full snapshot.
            logs = after_first_copy
            copied = evidence / 'created-copy'
            command('copy-out-created', ['cp', created + ':/tmp/payload', str(copied)])
            if copied.read_bytes() != payload.read_bytes() or stat.S_IMODE(copied.stat().st_mode) != 0o640:
                raise RuntimeError('Created copy content or mode differs')
            unchanged(created, before, 'created-after-copy')
            command('missing-workload-marker', ['cp', created + ':/tmp/workload-executed', str(evidence / 'unexpected-marker')], allowed=(1,))
            unchanged(created, before, 'created-after-failed-copy')
            unchanged_logs(created, logs, 'created-after-copy')
            no_workload_events(created, since, 'created-copy-events')
            case('created-copy-in-out', started)

            started = time.monotonic()
            command('start-created-after-copy', ['start', '--attach', created])
            finished = snapshot(created, 'created-after-start')
            if finished['status']['state'] != 'stopped' or finished.get('exitCode') != 0:
                raise RuntimeError('Created copy did not survive workload start')
            persisted = evidence / 'persisted-copy'
            logs = workload_logs(created)
            command('copy-out-after-workload', ['cp', created + ':/tmp/persisted', str(persisted)])
            if persisted.read_bytes() != payload.read_bytes():
                raise RuntimeError('Copied bytes did not persist')
            unchanged(created, finished, 'created-after-exited-copy')
            unchanged_logs(created, logs, 'created-after-exited-copy')
            case('copy-persists-through-start', started)

            script = ('printf copy-oracle-stdout; printf copy-oracle-stderr >&2; '
                      'mkdir /fixture; truncate -s 33554432 /fixture/sparse; '
                      'printf alpha | dd of=/fixture/sparse bs=1 seek=4093 conv=notrunc 2>/dev/null; '
                      'printf omega | dd of=/fixture/sparse bs=1 seek=33550336 conv=notrunc 2>/dev/null; '
                      'chmod 640 /fixture/sparse; ln /fixture/sparse /fixture/hardlink; '
                      'ln -s sparse /fixture/link; sync; exit 13')
            owned.append(exited)
            command('create-exited-fixture', ['create', *resources, '--name', exited, ALPINE, 'sh', '-ec', script])
            command('run-fixture-once', ['start', '--attach', exited], allowed=(0, 13))
            before = snapshot(exited, 'exited-before-copy')
            if before['status']['state'] != 'stopped' or before.get('exitCode') != 13:
                raise RuntimeError('Exited container state differs')
            started, since = time.monotonic(), time.time()
            logs = workload_logs(exited)
            if not logs or not any(row['size'] > 0 for row in logs.values()):
                raise RuntimeError('Exited fixture did not produce retained workload logs')
            log_bytes = b''.join((STATE / 'fork/app/containers' / exited / name).read_bytes() for name in logs)
            if b'copy-oracle-stdout' not in log_bytes or b'copy-oracle-stderr' not in log_bytes:
                raise RuntimeError('Exited fixture did not retain both workload output streams')
            expected = bytearray(33554432)
            expected[4093:4098], expected[-4096:-4091] = b'alpha', b'omega'
            expected_hash = hashlib.sha256(expected).hexdigest()
            sparse = evidence / 'stopped-sparse'
            command('copy-stopped-sparse', ['cp', exited + ':/fixture/sparse', str(sparse)])
            if sparse.stat().st_size != len(expected) or digest(sparse) != expected_hash or stat.S_IMODE(sparse.stat().st_mode) != 0o640:
                raise RuntimeError('Stopped sparse content or metadata differs')
            directory = evidence / 'directory-copy'
            command('copy-stopped-directory', ['cp', exited + ':/fixture', str(directory)])
            if (digest(directory / 'sparse') != expected_hash or digest(directory / 'hardlink') != expected_hash
                    or os.readlink(directory / 'link') != 'sparse'
                    or (directory / 'sparse').stat().st_ino != (directory / 'hardlink').stat().st_ino):
                raise RuntimeError('Stopped directory content, hardlink or symlink differs')
            link = evidence / 'copied-symlink'
            command('copy-stopped-symlink', ['cp', exited + ':/fixture/link', str(link)])
            if not link.is_symlink() or os.readlink(link) != 'sparse':
                raise RuntimeError('Default copy did not preserve symlink')
            followed = evidence / 'followed-symlink'
            command('copy-stopped-follow-symlink', ['cp', '-L', exited + ':/fixture/link', str(followed)])
            if followed.is_symlink() or digest(followed) != expected_hash:
                raise RuntimeError('Follow-symlink copy differs')
            command('copy-into-exited', ['cp', str(payload), exited + ':/fixture/added'])
            added = evidence / 'added-copy'
            command('copy-out-exited-added', ['cp', exited + ':/fixture/added', str(added)])
            if added.read_bytes() != payload.read_bytes():
                raise RuntimeError('Stopped copy-in did not persist')
            unchanged(exited, before, 'exited-after-copy')
            unchanged_logs(exited, logs, 'exited-after-copy')
            no_workload_events(exited, since, 'exited-copy-events')
            case('exited-copy-in-out-directory-sparse-hardlink-symlink', started)
            verify_prepared(args.prepared)
            result['semanticPassed'] = True
        except BaseException as error:
            result['failures'].append(type(error).__name__ + ': ' + str(error))
        finally:
            for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
                signal.signal(number, signal.SIG_IGN)
            for name in reversed(owned):
                try:
                    row = command('remove-owned-' + name, ['rm', '--force', name], allowed=(0, 1))
                    if row['status'] and (STATE / 'fork/app/containers' / name).exists():
                        raise RuntimeError('Owned container remains after failed removal: ' + name)
                except BaseException as error:
                    result['failures'].append('Owned cleanup: ' + str(error))
            try:
                stop_owned('fork')
            except BaseException as error:
                result['failures'].append('Runtime cleanup: ' + str(error))
            result['operations'] = runner.rows
            for row in runner.rows:
                row['logSHA256'] = digest(Path(row['log']))
            result['timingPairs'] = timing_pairs(runner.rows, oracle)
            expected_pairs = {row['fixture'] for row in oracle['operations'] if row['fixture'].startswith('copy-')}
            if {row['fixture'] for row in result['timingPairs']} != expected_pairs:
                result['failures'].append('Incomplete copy timing inventory')
            result['failures'].extend('Timing at least 10x or failed: ' + row['fixture']
                                      for row in result['timingPairs'] if not row['passed'])
            result['passed'] = result['semanticPassed'] and not result['failures']
            result['probeSHA256'] = digest(Path(__file__))
            (evidence / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
            suite = ET.Element('testsuite', name='stopped-container-copy', tests=str(len(runner.rows)))
            if result['failures']:
                test = ET.SubElement(suite, 'testcase', name='complete-contract', time='0')
                ET.SubElement(test, 'failure', message='Stopped-copy contract remains incomplete').text = '\n'.join(result['failures'])
                suite.set('tests', str(len(runner.rows) + 1))
            for row in runner.rows:
                test = ET.SubElement(suite, 'testcase', name=row['fixture'], time=str(row['seconds']))
                if row['status'] != 0 and row['fixture'] not in ('missing-workload-marker', 'run-fixture-once'):
                    ET.SubElement(test, 'failure', message='Command failed').text = row['log']
                pair = next((pair for pair in result['timingPairs'] if pair['fixture'] == row['fixture']), None)
                if pair:
                    props = ET.SubElement(test, 'properties')
                    for key in ('dockerSeconds', 'ratio', 'method'):
                        ET.SubElement(props, 'property', name=key, value=str(pair[key]))
                    if not pair['passed']:
                        ET.SubElement(test, 'failure', message='Copy duration at least 10x reference')
            ET.ElementTree(suite).write(evidence / 'junit.xml', encoding='utf-8', xml_declaration=True)
            matrix = ['# Stopped-copy timing', '', 'Retained single-sample Docker semantic oracle; no unchanged baseline rerun.', '',
                      '| Copy fixture | Docker seconds | Candidate seconds | Ratio | Gate |', '| --- | ---: | ---: | ---: | --- |']
            matrix.extend(f"| {row['fixture']} | {row['dockerSeconds']:.6f} | {row['candidateSeconds']:.6f} | {row['ratio']:.3f} | {'PASS' if row['passed'] else 'FAIL'} |" for row in result['timingPairs'])
            (evidence / 'matrix.md').write_text('\n'.join(matrix) + '\n')
            print(json.dumps({'passed': result['passed'], 'semanticPassed': result['semanticPassed'], 'failures': result['failures']}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
