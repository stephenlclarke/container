"""Serialize shared macOS services and recoverably quiesce idle family workers."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import time


LOCK = Path(f'/private/tmp/container-compose-runtime-{os.getuid()}.lock')
JOURNAL = Path.home() / 'Library/Application Support/ContainerFamily/config/container-only-host-recovery.json'
RUNNER = re.compile(r'actions\.runner\.stephenlclarke-(container|container-compose|devcontainer)\.([A-Za-z0-9._-]+)')
ENGINE = 'homebrew.mxcl.devcontainer'


def command(arguments: list[str], timeout: float = 30) -> str:
    environment = dict(os.environ)
    # Local keyring authentication is also needed when Actions supplies its
    # read-only workflow token. Never record the inherited environment.
    for key in ('GH_TOKEN', 'GITHUB_TOKEN'):
        environment.pop(key, None)
    result = subprocess.run(arguments, env=environment, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'Host coordination command failed: {arguments[0]} {arguments[1]}')
    return result.stdout.strip()


def processes() -> dict[int, dict]:
    inventory = {}
    for line in command(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,uid=,state=,lstart=,comm=']).splitlines():
        parts = line.split(maxsplit=10)
        if len(parts) != 11:
            raise RuntimeError('Incomplete host process inventory')
        pid, parent, group, uid = map(int, parts[:4])
        inventory[pid] = dict(pid=pid, parent=parent, group=group, uid=uid,
                              state=parts[4], started=' '.join(parts[5:10]), program=parts[10])
    return inventory


def labels() -> dict[str, int | None]:
    found = {}
    for line in command(['/bin/launchctl', 'list']).splitlines()[1:]:
        pid, _status, label = line.split(maxsplit=2)
        found[label] = int(pid) if pid.isdigit() else None
    return found


def identity(row: dict) -> tuple:
    return row['pid'], row['started'], row['uid'], row['program'], row['group']


def runner_state(label: str) -> dict:
    match = RUNNER.fullmatch(label)
    if match is None:
        raise RuntimeError('Unknown cooperating runner identity')
    repository, name = match.groups()
    pages = json.loads(command(['gh', 'api', '--paginate', '--slurp',
                               f'repos/stephenlclarke/{repository}/actions/runners?per_page=100']))
    matches = [row for page in pages for row in page['runners'] if row['name'] == name]
    if len(matches) != 1 or type(matches[0].get('busy')) is not bool:
        raise RuntimeError(f'Cannot establish runner state: {label}')
    return matches[0]


def wait_for(probe, seconds: float = 20) -> None:
    deadline = time.monotonic() + seconds
    while not probe():
        if time.monotonic() >= deadline:
            raise RuntimeError('Host service transition exceeded its deadline')
        time.sleep(0.1)


class HostLease:
    """Own the shared inode until originals and cooperating workers are restored."""

    def __init__(self, evidence: Path):
        self.evidence = evidence
        self.descriptor = None
        self.rows: list[dict] = []
        self.suspended: list[dict] = []
        self.record = {'owner': os.getpid(), 'evidence': str(evidence), 'workers': self.rows,
                       'restored': False, 'lock': str(LOCK)}

    def save(self) -> None:
        if JOURNAL.is_symlink():
            raise RuntimeError('Host recovery record must not be a symbolic link')
        if JOURNAL.exists():
            previous = json.loads(JOURNAL.read_text())
            if (previous.get('owner'), previous.get('evidence')) != (self.record['owner'], self.record['evidence']):
                raise RuntimeError('Preserving another run\'s host recovery authority')
        self.record['suspended'] = self.suspended
        value = json.dumps(self.record, indent=2) + '\n'
        (self.evidence / 'host-lease.json').write_text(value)
        JOURNAL.parent.mkdir(parents=True, exist_ok=True)
        temporary = JOURNAL.with_suffix('.tmp')
        with temporary.open('w') as output:
            os.chmod(temporary, 0o600)
            output.write(value)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(JOURNAL)

    def current_runner(self, loaded: dict, inventory: dict) -> str | None:
        if os.environ.get('GITHUB_ACTIONS') != 'true':
            return None
        repository = os.environ.get('GITHUB_REPOSITORY', '')
        name = os.environ.get('RUNNER_NAME', '')
        label = 'actions.runner.' + repository.replace('/', '-') + '.' + name
        ancestors = set()
        pid = os.getpid()
        while pid in inventory and pid not in ancestors:
            ancestors.add(pid)
            pid = inventory[pid]['parent']
        if (RUNNER.fullmatch(label) is None or loaded.get(label) not in ancestors
                or not any(Path(inventory[p]['program']).name == 'Runner.Worker' for p in ancestors)):
            raise RuntimeError('Cannot verify the current Actions runner process ancestry')
        return label

    def capture(self, label: str, pid: int | None, inventory: dict) -> dict:
        path = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise RuntimeError(f'Cannot preserve worker definition: {label}')
        data = path.read_bytes()
        definition = plistlib.loads(data)
        if definition.get('Label') != label:
            raise RuntimeError('Worker definition label changed')
        description = command(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{label}'])
        match = re.search(r'^\s*path = (.+)$', description, re.M)
        if match is None or Path(match[1]) != path:
            raise RuntimeError('Loaded worker does not match its saved definition')
        process = inventory.get(pid)
        if process is None or process['uid'] != os.getuid() or process['group'] != pid:
            raise RuntimeError('Worker has no independently owned service process group')
        members = [p for p in inventory.values() if p['group'] == pid]
        if any(p['uid'] != os.getuid() for p in members):
            raise RuntimeError('Worker process group has unrelated owners')
        if any(p['state'].startswith('T') for p in members):
            raise RuntimeError('A worker is already suspended; preserving its existing state')
        return dict(label=label, path=str(path), sha256=hashlib.sha256(data).hexdigest(),
                    process=process, bootout_started=False, restored=False)

    def idle(self, row: dict) -> None:
        if RUNNER.fullmatch(row['label']) and runner_state(row['label'])['busy']:
            raise RuntimeError('Active cooperating runner prevents qualification: ' + row['label'])
        inventory = processes()
        members = [p for p in inventory.values() if p['group'] == row['process']['group']]
        if any(Path(p['program']).name in {'Runner.Worker', 'container', 'container-runtime-linux'} for p in members):
            raise RuntimeError('Active worker or guest prevents qualification')
        if row['label'] == ENGINE and any(Path(p['program']).name in {
                'container', 'container-runtime-linux', 'devcontainer', 'compose'} for p in inventory.values()):
            raise RuntimeError('An active container session prevents engine quiescence')

    def resume(self) -> None:
        failures = []
        for group in list(reversed(self.suspended)):
            current = processes()
            members = [p for p in current.values() if p['group'] == group['group']]
            if not members:
                continue
            originals = {identity(p) for p in group['members']}
            if any(identity(p) in originals for p in members):
                try:
                    os.killpg(group['group'], signal.SIGCONT)
                except ProcessLookupError:
                    pass
                except OSError:
                    failures.append(group)
            else:
                failures.append(group)
        self.suspended = failures
        if failures:
            raise RuntimeError('Could not resume a cooperating worker; retained recovery record')

    def quiesce(self, row: dict) -> None:
        self.idle(row)
        prior = row['process']
        current = processes().get(prior['pid'])
        if current is None or identity(current) != identity(prior):
            raise RuntimeError('Worker process changed before quiescence')
        self.suspended.append({'group': prior['group'], 'members': [
            p for p in processes().values() if p['group'] == prior['group']]})
        # Journal before the first signal, then freeze the complete group to
        # close the assignment race between GitHub busy checks and bootout.
        self.save()
        try:
            os.killpg(prior['group'], signal.SIGSTOP)

            def stopped():
                members = [p for p in processes().values() if p['group'] == prior['group']]
                if not members or not all(p['state'].startswith('T') for p in members):
                    return False
                group = self.suspended[-1]
                originals = {identity(p) for p in group['members']}
                if not any(identity(p) in originals for p in members):
                    raise RuntimeError('Suspended worker group lost its original identity')
                # A child may have spawned between the first snapshot and
                # SIGSTOP. Once every member is frozen, bind those children
                # too so they can be resumed if the leader exits at bootout.
                group['members'] = members
                self.save()
                return True

            wait_for(stopped, 5)
            self.idle(row)
            row['bootout_started'] = True
            self.save()
            command(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{row["label"]}'])
        finally:
            self.resume()
        wait_for(lambda: row['label'] not in labels() and not any(
            p['group'] == prior['group'] for p in processes().values()))

    def acquire(self) -> None:
        self.descriptor = os.open(LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        info = os.fstat(self.descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o022:
            raise RuntimeError('Shared runtime lease is not a private single-owner file')
        fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if JOURNAL.exists() or JOURNAL.is_symlink():
            raise RuntimeError('Previous host restoration is incomplete: ' + str(JOURNAL))
        loaded, inventory = labels(), processes()
        current = self.current_runner(loaded, inventory)
        self.record['current_runner'] = current
        self.record['github_run_id'] = os.environ.get('GITHUB_RUN_ID') if current else None
        for label, pid in loaded.items():
            if label != current and (RUNNER.fullmatch(label) or label == ENGINE):
                self.rows.append(self.capture(label, pid, inventory))
        # Refuse known busy work before changing any service.
        for row in self.rows:
            self.idle(row)
        for row in self.rows:
            self.quiesce(row)
        self.record['acquired'] = True
        self.save()

    def ready(self, row: dict) -> bool:
        if labels().get(row['label']) is None:
            return False
        description = command(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{row["label"]}'])
        match = re.search(r'^\s*path = (.+)$', description, re.M)
        if match is None or match[1] != row['path']:
            raise RuntimeError('Restored worker definition was replaced')
        if RUNNER.fullmatch(row['label']):
            return runner_state(row['label'])['status'] == 'online'
        endpoint = command(['devcontainer', 'context', '--format', 'value'])
        if not endpoint.startswith('unix:///') or '\n' in endpoint:
            raise RuntimeError('Invalid restored engine endpoint')
        try:
            return command(['/usr/bin/curl', '--fail', '--silent', '--max-time', '5',
                            '--unix-socket', endpoint[7:], 'http://localhost/_ping'], timeout=6) == 'OK'
        except (RuntimeError, subprocess.TimeoutExpired):
            # launchd starts the engine asynchronously; connection refusal is
            # expected until it binds the socket, within the outer deadline.
            return False

    def restore(self, *, restore_workers: bool = True) -> None:
        errors = []
        try:
            self.resume()
        except Exception as error:
            errors.append(str(error))
        if not restore_workers:
            self.record['failures'] = ['Original runtime cleanup failed; workers remain quiesced'] + errors
            self.save()
            raise RuntimeError(self.record['failures'][0])
        for row in reversed(self.rows):
            if not row['bootout_started']:
                continue
            try:
                data = Path(row['path']).read_bytes()
                if hashlib.sha256(data).hexdigest() != row['sha256']:
                    raise RuntimeError('Worker definition changed: ' + row['label'])
                if row['label'] not in labels():
                    command(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', row['path']])

                wait_for(lambda: self.ready(row), 90)
                row['restored'] = True
            except Exception as error:
                errors.append(str(error))
        self.record['restored'] = not errors
        self.record['failures'] = errors
        # Do not overwrite another run's recovery record after admission fails.
        if self.rows or self.record.get('acquired'):
            self.save()
            if not errors:
                JOURNAL.unlink()
        if errors:
            raise RuntimeError('; '.join(errors))

    def close(self) -> None:
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None
