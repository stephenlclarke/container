#!/usr/bin/env python3
"""Run a qualification target with bounded commands and restore an owned Colima start."""

import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess

from fork_benchmark import BAZEL, COMMAND_LOCK_ENV, ROOT, STORAGE, Runner, command_lease
from bazel_environment import bazel_environment
from preflight import CONFIG, apple_runtime_slot_ready, check
from failed_api_hold import hold_failed_api
from runtime_benchmark import INSTALLS, StockSlot
from host_lease import HostLease
from release_install import require_restored
from runtime_coverage import require_idle, verify_binaries


def output(arguments: list[str]) -> str:
    return subprocess.check_output(arguments, stdin=subprocess.DEVNULL, text=True, timeout=30).strip()


class ColimaLease:
    """Only start a stopped default profile; never stop someone else's workload."""

    def __init__(self, evidence: Path):
        self.evidence = evidence
        self.record = {'started_by_this_run': False, 'restored': False}
        self.command_descriptors: tuple[int, ...] = ()

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
                               timeout=180, check=True, pass_fds=self.command_descriptors)
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
                                   stdout=log, stderr=subprocess.STDOUT, timeout=120, check=True,
                                   pass_fds=self.command_descriptors)
            elif current['status'] != 'Stopped':
                raise RuntimeError('Colima state is uncertain after a failed start; inspect retained startup logs')
        self.record['restored'] = True
        self.save()


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def shutdown_idle_bazel(evidence: Path, workspace: str) -> None:
    """An inherited lease must not keep an idle workspace server alive forever."""
    directory = Path(workspace)
    if not directory.is_absolute() or not directory.is_dir():
        raise RuntimeError('Recorded Bazel workspace is unavailable; manual recovery is required')
    with (evidence / f'bazel-shutdown-{os.getpid()}.log').open('w') as log:
        subprocess.run([str(BAZEL), '--output_user_root=' + str(STORAGE / 'output'),
                        '--noblock_for_lock', 'shutdown'], cwd=directory,
                       env=bazel_environment(os.environ), stdin=subprocess.DEVNULL,
                       stdout=log, stderr=subprocess.STDOUT, timeout=30, check=True)


def acquire_cleanup_commands(evidence: Path, commands: ExitStack, workspace: str | None) -> tuple[int, ...]:
    environment = {COMMAND_LOCK_ENV: str(evidence.resolve() / 'commands.lock')}
    try:
        return commands.enter_context(command_lease(environment, exclusive=True))
    except BlockingIOError:
        if not isinstance(workspace, str):
            raise
        # The official non-blocking shutdown refuses a busy server. Any other
        # surviving command still prevents the second exclusive-lock attempt.
        shutdown_idle_bazel(evidence, workspace)
        return commands.enter_context(command_lease(environment, exclusive=True))


def verify_installations(evidence: Path) -> None:
    """An uncertain binary replacement keeps workers quiesced for recovery."""
    for installation in (INSTALLS / 'fork/install', INSTALLS / 'stock/install',
                         INSTALLS / 'containerization-integration/bin'):
        require_idle(installation)
    require_restored(evidence / 'install')
    coverage = evidence / 'integration/coverage'
    if coverage.exists():
        record = json.loads((coverage / 'coverage.json').read_text())
        expected = record.get('original_binaries')
        if record.get('restored') is not True or not isinstance(expected, dict) or not expected:
            raise RuntimeError('Instrumented installation restoration is unconfirmed; inspect ' + str(coverage))
        verify_binaries(INSTALLS / 'fork/install', expected)


def restore_host(evidence: Path, host: HostLease, lease: ColimaLease, slot: StockSlot,
                 commands: ExitStack, result: dict) -> None:
    """Restore only after surviving command holders have released their leases."""
    cleanup_ok = True
    # Close rather than unlock: an inherited child descriptor must retain its
    # shared lease. A separate open description must win exclusive ownership.
    commands.close()
    try:
        lease.command_descriptors = acquire_cleanup_commands(evidence, commands, host.record.get('bazel_workspace'))
    except BaseException as error:
        cleanup_ok = False
        result['failures'].append('Commands have not finished or their lease is unavailable: ' + str(error))
    else:
        try:
            verify_installations(evidence)
        except BaseException as error:
            cleanup_ok = False
            result['failures'].append(str(error))
        for resource in (lease, slot):
            try:
                resource.restore()
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append(str(error))
    try:
        host.restore(restore_workers=cleanup_ok)
    except BaseException as error:
        cleanup_ok = False
        result['failures'].append(str(error))
    finally:
        host.close()
    if not cleanup_ok:
        result['passed'] = False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--target', choices=['bazel-qualify', 'bazel-artifact-check', 'bazel-service-artifacts', 'bazel-service-integration', 'bazel-eof-integration'], default='bazel-artifact-check')
    parser.add_argument('--profile', choices=['runtime', 'release'], default='runtime')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(number, interrupted)
    config = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    admission = check(args.profile, config)
    (args.evidence / 'preflight.json').write_text(json.dumps(admission, indent=2) + '\n')
    failed_checks = [row['check'] for row in admission.get('checks', []) if not row['ready']]
    pending_api_hold = (not admission['ready'] and failed_checks == ['apple-runtime-slot']
                        and config.get('failed_api_hold') is not None)
    if not admission['ready'] and not pending_api_hold:
        raise SystemExit('Unattended preflight failed; see ' + str(args.evidence / 'preflight.json'))
    with (STORAGE / 'qualification.lock').open('w') as lock, ExitStack() as commands:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        host = HostLease(args.evidence)
        lease = ColimaLease(args.evidence)
        slot = StockSlot(args.evidence)
        result = {'passed': False, 'target': args.target, 'failures': []}
        try:
            # Keep dormant originals aside across every runtime stage; restoring
            # between stages lets background clients reactivate them mid-run.
            command_lock = args.evidence.resolve() / 'commands.lock'
            host.record['command_lock'] = str(command_lock)
            host.record['bazel_workspace'] = str(ROOT)
            descriptor = os.open(command_lock, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
            os.close(descriptor)
            lease.command_descriptors = commands.enter_context(command_lease({COMMAND_LOCK_ENV: str(command_lock)}))
            host.acquire()
            if pending_api_hold:
                hold_failed_api(slot, config['failed_api_hold'])
                if not apple_runtime_slot_ready():
                    raise RuntimeError('Original runtime slot remains unavailable after explicit API stop')
                (args.evidence / 'preflight-before-api-hold.json').write_text(json.dumps(admission, indent=2) + '\n')
                for item in admission['checks']:
                    if item['check'] == 'apple-runtime-slot':
                        item.update(ready=True, action='', explicit_failed_api_hold=True)
                admission['ready'] = True
                (args.evidence / 'preflight.json').write_text(json.dumps(admission, indent=2) + '\n')
            slot.acquire()
            lease.acquire()
            # Startup is now complete, including readiness and config checks.
            # Unlock its shared open description before closing it: persistent
            # Lima helpers inherit that description but cannot dispatch tests.
            # Runner opens independent leases for all subsequent controllers.
            for descriptor in lease.command_descriptors:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            commands.close()
            lease.command_descriptors = ()
            runner = Runner(args.evidence, STORAGE)
            runner.env[COMMAND_LOCK_ENV] = str(command_lock)
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
            # Restoration must finish even if cancellation is repeated.
            for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
                signal.signal(number, signal.SIG_IGN)
            restore_host(args.evidence, host, lease, slot, commands, result)
            (args.evidence / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
        if not result['passed']:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
