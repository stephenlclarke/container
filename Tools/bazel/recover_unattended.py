#!/usr/bin/env python3
"""Restore recorded host leases after the qualification wrapper has been killed."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import stat

from fork_benchmark import ROOT
from host_lease import HostLease, JOURNAL, LOCK, processes
from runtime_benchmark import INSTALLS, STORAGE, RuntimeRunner, StockSlot, checked, stop_owned
from runtime_coverage import RuntimeCoverage, require_idle, verify_binaries
from unattended import ColimaLease, shutdown_idle_bazel, verify_installations


def private_bytes(path: Path) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o022):
            raise RuntimeError('Recorded coverage evidence is not a private regular file: ' + str(path))
        with os.fdopen(os.dup(descriptor), 'rb') as stream:
            return stream.read()
    finally:
        os.close(descriptor)


def private_directory(path: Path) -> None:
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o022):
        raise RuntimeError('Recorded coverage directory is not privately owned: ' + str(path))


def recorded_binaries(directory: Path, expected: dict) -> None:
    if not isinstance(expected, dict) or not expected:
        raise RuntimeError('Recorded coverage binary inventory is incomplete')
    for name, sha in expected.items():
        if (not isinstance(name, str) or not name or Path(name).is_absolute()
                or Path(name).as_posix() != name or '..' in Path(name).parts
                or not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{64}', sha)):
            raise RuntimeError('Recorded coverage binary identity is malformed')
        member = directory
        for part in Path(name).parts[:-1]:
            member /= part
            private_directory(member)
        member /= Path(name).name
        private_bytes(member)
    verify_binaries(directory, expected)


def restore_recorded_coverage(evidence: Path, record: dict) -> bool:
    """Resume only a failed, fingerprinted profile swap under recovery's four locks."""
    integration = evidence / 'integration'
    if not integration.exists() and not integration.is_symlink():
        return False
    for parent in (evidence, integration):
        private_directory(parent)
    directory = integration / 'coverage'
    if not directory.exists() and not directory.is_symlink():
        return False
    private_directory(evidence / 'runtime-smoke')
    private_directory(directory)
    path = directory / 'coverage.json'
    before = private_bytes(path)
    coverage_record = json.loads(before)
    if coverage_record.get('restored') is True:
        return False  # Normal finish already restored the binaries.
    if (coverage_record.get('restored') is not False or coverage_record.get('passed') is not False
            or not isinstance(coverage_record.get('failures'), list)
            or any(not isinstance(item, str) for item in coverage_record['failures'])
            or record.get('bazel_workspace') != str(ROOT)
            or coverage_record.get('revision') != checked(['git', 'rev-parse', 'HEAD'], cwd=ROOT)
            or checked(['git', 'status', '--porcelain'], cwd=ROOT)):
        raise RuntimeError('Recorded coverage source or failed state is unconfirmed')
    acceptance = evidence / 'acceptance.json'
    if acceptance.exists() and json.loads(private_bytes(acceptance)).get('passed') is not False:
        raise RuntimeError('Cannot restore a coverage backup for a qualified or unknown run')
    installation = INSTALLS / 'fork/install'
    temporary = Path(coverage_record.get('recovery_directory', ''))
    if (temporary.parent != installation.parent
            or not re.fullmatch(r'coverage-install-[A-Za-z0-9_]{8}', temporary.name)):
        raise RuntimeError('Recorded coverage recovery path is outside the private installation')
    for owned in (INSTALLS, installation.parent, installation, temporary, temporary / 'previous'):
        private_directory(owned)
    backup = temporary / 'previous'
    marker = {'owner': 'container-runtime-benchmark', 'lane': 'fork', 'schema': 1}
    for owned in (installation, backup):
        if json.loads(private_bytes(owned / '.runtime-benchmark-owner.json')) != marker:
            raise RuntimeError('Recorded coverage installation ownership changed')
        require_idle(owned)
    original = json.loads(private_bytes(evidence / 'runtime-smoke/fork-fingerprint.json'))
    instrumented = json.loads(private_bytes(directory / 'fork-fingerprint.json'))
    if coverage_record.get('original_binaries') != original.get('binaries'):
        raise RuntimeError('Recorded original coverage fingerprint changed')
    recorded_binaries(backup, original['binaries'])
    recorded_binaries(installation, instrumented['binaries'])
    preserved = directory / 'coverage-before-recovery.json'
    try:
        descriptor = os.open(preserved, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        # A prior finish() may have appended its own failure before replacing
        # binaries. Keep the first record immutable, but permit a retry only
        # when every other field is identical and failures were append-only.
        original_record = json.loads(private_bytes(preserved))
        if (not isinstance(original_record.get('failures'), list)
                or {key: value for key, value in coverage_record.items() if key != 'failures'} !=
                {key: value for key, value in original_record.items() if key != 'failures'}
                or coverage_record['failures'][:len(original_record['failures'])] !=
                original_record['failures']):
            raise RuntimeError('Previously preserved failed coverage evidence changed')
    else:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(before)
            stream.flush()
            os.fsync(stream.fileno())
    previous_failures = list(coverage_record['failures'])
    coverage = RuntimeCoverage.__new__(RuntimeCoverage)
    coverage.runner = RuntimeRunner(evidence / 'integration', STORAGE)
    coverage.evidence = directory
    coverage.installation = installation
    coverage.original = original
    coverage.backup = backup
    coverage.result = coverage_record
    coverage.finish(False)
    after = json.loads(private_bytes(path))
    if (after.get('restored') is not True or after.get('passed') is not False
            or after.get('failures') != previous_failures or 'recovery_directory' in after):
        raise RuntimeError('Failed coverage restoration did not retain its original outcome')
    recorded_binaries(installation, original['binaries'])
    return True


def recover(evidence: Path) -> dict:
    """Recover only this invocation, with the original owner gone and all locks held."""
    evidence = evidence.resolve()
    result = {'restored': False, 'needed': False, 'failures': [], 'evidence': str(evidence)}
    descriptors = []
    command_descriptors = ()
    host = None
    try:
        for path in (STORAGE / 'qualification.lock', LOCK, INSTALLS / 'benchmark.lock'):
            descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            descriptors.append(descriptor)
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or info.st_mode & 0o022):
                raise RuntimeError('Recovery lock is not a private single-owner file: ' + str(path))
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if JOURNAL.is_symlink():
            raise RuntimeError('Host recovery record must not be a symbolic link')
        if not JOURNAL.exists():
            previous = evidence / 'host-lease.json'
            if previous.exists() and json.loads(previous.read_text()).get('restored') is not True:
                raise RuntimeError('Host restoration is unconfirmed and its recovery journal is missing')
            verify_installations(evidence)
            result['restored'] = True
            return result
        record = json.loads(JOURNAL.read_text())
        if record.get('evidence') != str(evidence):
            raise RuntimeError('Preserving another invocation\'s host recovery authority')
        if os.environ.get('GITHUB_ACTIONS') == 'true' and record.get('github_run_id') != os.environ.get('GITHUB_RUN_ID'):
            raise RuntimeError('Host recovery belongs to a different GitHub run')
        if type(record.get('owner')) is not int or record['owner'] <= 0 or record['owner'] in processes():
            raise RuntimeError('Qualification owner is still active or unconfirmed; refusing recovery')
        if 'command_lock' not in record:
            raise RuntimeError('Legacy recovery record has no command lease; manual verification is required')
        path = evidence / 'commands.lock'
        if record['command_lock'] != str(path):
            raise RuntimeError('Qualification command lease does not match this invocation')
        descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        descriptors.append(descriptor)
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o022):
            raise RuntimeError('Qualification command lease is not a private single-owner file')
        # Runner passes its shared descriptor to each command, including
        # separate-session controllers that can outlive a killed wrapper.
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            workspace = record.get('bazel_workspace')
            if not isinstance(workspace, str):
                raise
            shutdown_idle_bazel(evidence, workspace)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        command_descriptors = (descriptor,)
        result.update(needed=True, original_owner=record['owner'])
        host = HostLease(evidence)
        host.record = record
        host.rows = record['workers']
        host.suspended = record['suspended']
        host.record['recovered_by'] = os.getpid()
        cleanup_ok = True
        try:
            stop_owned('fork')
            # A previous restoration attempt may already have loaded originals.
            # Never stop those services as though they were private stock helpers.
            originals = evidence / 'service-restoration.json'
            rows = json.loads(originals.read_text()) if originals.exists() else []
            stop_owned('stock', originals=rows)
            result['profiled_installation_recovered'] = restore_recorded_coverage(evidence, record)
            verify_installations(evidence)
        except BaseException as error:
            cleanup_ok = False
            result['failures'].append(str(error))
        for name, constructor, attribute in (
                ('colima-lease.json', ColimaLease, 'record'),
                ('service-restoration.json', StockSlot, 'saved')):
            path = evidence / name
            if not path.exists():
                continue  # Each lease records intent before its first mutation.
            try:
                resource = constructor(evidence)
                setattr(resource, attribute, json.loads(path.read_text()))
                if isinstance(resource, ColimaLease):
                    resource.command_descriptors = command_descriptors
                resource.restore()
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append(str(error))
        try:
            host.restore(restore_workers=cleanup_ok)
        except BaseException as error:
            cleanup_ok = False
            result['failures'].append(str(error))
        result['restored'] = cleanup_ok
        return result
    except BaseException as error:
        result['failures'].append(str(error))
        return result
    finally:
        # Keep each attempt, including failed recovery, separate from qualification.
        try:
            if evidence.is_dir():
                (evidence / f'recovery-{os.getpid()}.json').write_text(json.dumps(result, indent=2) + '\n')
        except OSError as error:
            result['restored'] = False
            result['failures'].append('Cannot retain recovery outcome: ' + str(error))
        finally:
            try:
                if host:
                    host.close()
            finally:
                for descriptor in reversed(descriptors):
                    os.close(descriptor)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    result = recover(args.evidence)
    print(json.dumps(result, indent=2))
    if not result['restored']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
