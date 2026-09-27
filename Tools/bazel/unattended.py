#!/usr/bin/env python3
"""Run a qualification target with bounded commands and restore an owned Colima start."""

import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import signal
import subprocess

from fork_benchmark import ROOT, STORAGE, Runner
from preflight import CONFIG, check


def output(arguments: list[str]) -> str:
    return subprocess.check_output(arguments, stdin=subprocess.DEVNULL, text=True, timeout=30).strip()


class ColimaLease:
    """Only start a stopped default profile; never stop someone else's workload."""

    def __init__(self, evidence: Path):
        self.evidence = evidence
        self.record = {'started_by_this_run': False, 'restored': False}

    def save(self) -> None:
        (self.evidence / 'colima-lease.json').write_text(json.dumps(self.record, indent=2) + '\n')

    def acquire(self) -> None:
        profiles = [json.loads(row) for row in output(['colima', 'list', '--json']).splitlines()]
        current = next((p for p in profiles if p['name'] == 'default'), None)
        if current is None or current['arch'] != 'aarch64' or current['runtime'] != 'docker':
            raise RuntimeError('Configure the default arm64 Docker Colima profile during setup')
        self.record.update(profile=current, docker_context=output(['docker', 'context', 'show']))
        config = Path.home() / '.colima/default/colima.yaml'
        self.record['config_sha256'] = hashlib.sha256(config.read_bytes()).hexdigest()
        self.save()
        if current['status'] == 'Stopped':
            # Record ownership before launching so a failed start is also cleaned up.
            self.record['started_by_this_run'] = True
            self.save()
            with (self.evidence / 'colima-start.log').open('w') as log:
                subprocess.run(['colima', 'start', '--activate=false', '--save-config=false',
                                '--mount', str(Path.home()) + ':w', '--mount', str(STORAGE) + ':w'],
                               stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                               timeout=180, check=True)
        elif current['status'] != 'Running':
            raise RuntimeError('Colima is changing state; refusing to interfere')
        if output(['docker', '--context', 'colima', 'ps', '-q']):
            raise RuntimeError('Existing Docker workloads prevent isolated qualification')
        subprocess.run(['colima', 'ssh', '--', 'test', '-w', str(STORAGE)], check=True,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        if output(['docker', 'context', 'show']) != self.record['docker_context']:
            raise RuntimeError('The selected Docker context changed during Colima startup')
        if hashlib.sha256(config.read_bytes()).hexdigest() != self.record['config_sha256']:
            raise RuntimeError('Colima changed its saved configuration unexpectedly')

    def restore(self) -> None:
        if self.record['started_by_this_run']:
            profiles = [json.loads(row) for row in output(['colima', 'list', '--json']).splitlines()]
            current = next(p for p in profiles if p['name'] == 'default')
            if current['status'] == 'Running':
                if output(['docker', '--context', 'colima', 'ps', '-q']):
                    raise RuntimeError('Containers remain active; preserving Colima and reporting incomplete cleanup')
                with (self.evidence / 'colima-stop.log').open('w') as log:
                    subprocess.run(['colima', 'stop'], stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, timeout=120, check=True)
            elif current['status'] != 'Stopped':
                raise RuntimeError('Colima state is uncertain after a failed start; inspect retained startup logs')
        self.record['restored'] = True
        self.save()


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--target', choices=['bazel-qualify', 'bazel-artifact-check', 'bazel-service-artifacts', 'bazel-service-integration'], default='bazel-artifact-check')
    parser.add_argument('--profile', choices=['runtime', 'release'], default='runtime')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(number, interrupted)
    config = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    admission = check(args.profile, config)
    (args.evidence / 'preflight.json').write_text(json.dumps(admission, indent=2) + '\n')
    if not admission['ready']:
        raise SystemExit('Unattended preflight failed; see ' + str(args.evidence / 'preflight.json'))
    with (STORAGE / 'qualification.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        lease = ColimaLease(args.evidence)
        result = {'passed': False, 'target': args.target, 'failures': []}
        try:
            lease.acquire()
            runner = Runner(args.evidence, STORAGE)
            row = runner.run('qualification', 'fork', args.target, 0,
                             ['make', args.target, 'QUALIFICATION_EVIDENCE=' + str(args.evidence)],
                             ROOT, timeout=21600 if args.target == 'bazel-qualify' else 7200)
            if row['status']:
                raise RuntimeError('Qualification failed: ' + row['log'])
            result['passed'] = True
        except BaseException as error:
            result['failures'].append(str(error))
            raise
        finally:
            try:
                lease.restore()
            except BaseException as error:
                result['passed'] = False
                result['failures'].append(str(error))
                raise
            finally:
                (args.evidence / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
        if not result['passed']:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
