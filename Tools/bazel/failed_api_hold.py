"""Explicitly hold one diagnosed failed installation during qualification."""

import json
import os
from pathlib import Path
import plistlib
import re
import shutil

from host_lease import processes, wait_for
from runtime_benchmark import checked, digest, service_is_inactive, services

LABEL = 'com.apple.container.apiserver'
APP = Path.home() / 'Library/Application Support/com.apple.container'
PLIST = APP / 'apiserver/apiserver.plist'
HELPERS = {LABEL, 'com.apple.container.container-core-images',
           'com.apple.container.container-network-vmnet', 'com.apple.container.machine-apiserver',
           'sh.brew.container'}


def runtime_is_stopped() -> bool:
    for row in processes().values():
        name = Path(row['program']).name
        if (name in {'container', 'container-apiserver', 'container-runtime-linux', 'machine-apiserver', 'devcontainer-engine'}
                or 'Virtualization.VirtualMachine' in name):
            return False
    return True


def stopped_records() -> dict[str, str]:
    """Corroborate no running saved workload; this is not a live API inventory."""
    records = {}
    for directory in (APP / 'containers').iterdir():
        if not directory.is_dir() or directory.is_symlink():
            raise RuntimeError('Unrecognised original container state entry')
        path = directory / 'lifecycle-v2.json'
        state = json.loads(path.read_text())['snapshot']
        if (state.get('running') is not False or state.get('restarting') is not False
                or state.get('paused') is not False or state.get('pid') != 0
                or state.get('removalInProgress') is not False):
            raise RuntimeError('Saved original workload is not stopped')
        records[str(path)] = digest(path)
    return records


def inspect_failed_api(approval: dict) -> tuple[str, dict[str, str]]:
    """Bind an operator decision to unchanged code, registration and failure state."""
    if (not isinstance(approval, dict) or set(approval) != {'program', 'binary_sha256', 'plist_sha256'}
            or not isinstance(approval['program'], str)
            or any(not isinstance(approval[key], str) or re.fullmatch('[0-9a-f]{64}', approval[key]) is None
                   for key in ('binary_sha256', 'plist_sha256'))):
        raise RuntimeError('Invalid explicit failed API hold configuration')
    if PLIST.is_symlink() or digest(PLIST) != approval['plist_sha256']:
        raise RuntimeError('Original failed API definition changed')
    definition = plistlib.loads(PLIST.read_bytes())
    if (definition.get('Label') != LABEL
            or definition.get('ProgramArguments') != [approval['program'], 'start']
            or definition.get('EnvironmentVariables', {}).get('CONTAINER_APP_ROOT') != str(APP)):
        raise RuntimeError('Failed API definition does not match its approved identity')
    if digest(Path(approval['program'])) != approval['binary_sha256']:
        raise RuntimeError('Original failed API binary changed')
    original = services('com.apple.container.') + services('sh.brew.container')
    if LABEL not in {label for _, label in original}:
        raise RuntimeError('Approved failed API is not registered')
    api = ''
    for pid, label in original:
        if label not in HELPERS or pid != '-':
            raise RuntimeError('Active or unknown original service prevents failed API hold')
        description = checked(['launchctl', 'print', f'gui/{os.getuid()}/{label}'], timeout=20)
        if label != LABEL:
            if not service_is_inactive(description):
                raise RuntimeError('Another original service is not inactive')
            continue
        required = {'path': str(PLIST), 'program': approval['program'],
                    'state': 'spawn scheduled', 'active count': '0', 'last exit code': '1'}
        for field, value in required.items():
            if re.search(r'^\t' + re.escape(field) + ' = ' + re.escape(value) + '$', description, re.M) is None:
                raise RuntimeError('Original API no longer matches the diagnosed failed state')
        if re.search(r'^\tpid = ', description, re.M):
            raise RuntimeError('Original API is executing; preserve its state')
        api = description
    if not runtime_is_stopped():
        raise RuntimeError('A runtime process prevents the explicit failed API hold')
    return api, stopped_records()


def hold_failed_api(slot, approval: dict) -> None:
    """Called only under HostLease after all other admission checks have passed."""
    description, records = inspect_failed_api(approval)
    (slot.evidence / (LABEL + '.before.txt')).write_text(description)
    shutil.copy2(PLIST, slot.evidence / (LABEL + '.original.plist'))
    # Recheck after retaining the snapshot, before recording any stop intent.
    current, current_records = inspect_failed_api(approval)
    if records != current_records:
        raise RuntimeError('Original workload records changed before failed API hold')
    (slot.evidence / 'failed-api-hold.json').write_text(json.dumps({
        'explicit_setup': True, 'inventory_confirmed': False,
        'identity': approval, 'stopped_record_sha256': records,
        'description_before_stop': current,
        'limitation': 'Restoring the original registration does not repair its pre-existing failure.',
    }, indent=2) + '\n')
    # Journal intent in the standard transaction before bootout. Even if bootout
    # or the process is interrupted, normal recovery restores this original.
    slot.saved.append(dict(label=LABEL, path=str(PLIST), sha256=approval['plist_sha256'],
                           unloaded=True, explicitly_stopped_failed_api=True))
    slot.persist()
    checked(['launchctl', 'bootout', f'gui/{os.getuid()}/{LABEL}'], timeout=20)
    if any(label == LABEL for _, label in services('com.apple.container.')):
        raise RuntimeError('Original failed API survived the requested stop')
    wait_for(runtime_is_stopped, 5)
    if stopped_records() != records:
        raise RuntimeError('Original workload records changed during failed API stop')
