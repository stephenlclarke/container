#!/usr/bin/env python3
"""Restore recorded host leases after the qualification wrapper has been killed."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import stat

from host_lease import HostLease, JOURNAL, LOCK, processes
from runtime_benchmark import INSTALLS, STORAGE, StockSlot, stop_owned
from unattended import ColimaLease, shutdown_idle_bazel, verify_installations


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
