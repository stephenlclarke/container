#!/usr/bin/env python3
"""Exercise the signed archive in the stable private install slot, then restore it."""

import argparse
import fcntl
import json
from pathlib import Path
import shutil
import tarfile
import tempfile

from fork_benchmark import digest, install_signal_handlers
from runtime_benchmark import INSTALLS, STATE, RuntimeRunner, checked, own, reset_state, run_lane, stop_owned
from runtime_integration import verify_prepared


def checked_payload(archive: Path, destination: Path, expected: dict[str, str]) -> None:
    with tarfile.open(archive) as package:
        package.extractall(destination, filter='data')
    actual = {str(p.relative_to(destination)): digest(p) for p in destination.rglob('*') if p.is_file()}
    if actual != expected or any(p.is_symlink() for p in destination.rglob('*')):
        raise RuntimeError('Installed package payload differs from the verified release')


def run(evidence: Path, release: Path) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    result = {'passed': False, 'failures': []}
    runner = RuntimeRunner(evidence, STATE)
    installation = INSTALLS / 'fork/install'
    moved = False
    with (INSTALLS / 'benchmark.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            verify_prepared(release)
            qualification = json.loads((release / 'release-artifact.json').read_text())
            if not qualification['passed']:
                raise RuntimeError('Release packaging did not pass')
            archive = release / 'container-homebrew-arm64.tar.gz'
            if digest(archive) != qualification['archives'][archive.name]:
                raise RuntimeError('Release archive changed after verification')
            for name in ['source-inputs.json', 'guest-artifact.json', 'builder-artifact.json']:
                shutil.copy2(release / name, evidence / name)
            metadata = json.loads((release / 'fork-fingerprint.json').read_text())
            metadata['binaries'] = qualification['payload']
            metadata['installed_archive_sha256'] = digest(archive)
            (evidence / 'fork-fingerprint.json').write_text(json.dumps(metadata, indent=2) + '\n')
            stop_owned('fork')
            own(installation, 'fork')
            if any(path.startswith(str(installation) + '/') for path in checked(['ps', '-axo', 'comm=']).splitlines()):
                raise RuntimeError('Private installation still has active processes; refusing replacement')
            temporary = Path(tempfile.mkdtemp(prefix='release-install-', dir=installation.parent))
            result['recovery_directory'] = str(temporary)
            try:
                payload = temporary / 'payload'
                payload.mkdir()
                checked_payload(archive, payload, qualification['payload'])
                # The archive intentionally has no local ownership marker.
                marker = installation / '.runtime-benchmark-owner.json'
                shutil.copy2(marker, payload / marker.name)
                backup = temporary / 'previous'
                installation.rename(backup)
                moved = True
                try:
                    payload.rename(installation)
                    own(installation, 'fork')
                    kernel = reset_state('fork', metadata['init_image'], metadata['builder_image'])
                    if kernel != metadata['kernel_sha256']:
                        raise RuntimeError('Release installation kernel changed')
                    run_lane(runner, 'fork', 1)
                    result.update(passed=True, archive_sha256=digest(archive),
                                  notarized=qualification['notarized'], source=qualification['source'],
                                  scope='Signed tar installation, explicit matching guest/builder configuration and eight live workloads')
                finally:
                    stop_owned('fork')
                    logs = STATE / 'fork/logs'
                    if logs.exists():
                        shutil.copytree(logs, evidence / 'server-logs')
                    if installation.exists():
                        own(installation, 'fork')
                        shutil.rmtree(installation)
                    backup.rename(installation)
                    moved = False
                    result['previous_installation_restored'] = True
            finally:
                if not moved:
                    shutil.rmtree(temporary)
                    result.pop('recovery_directory', None)
        except BaseException as error:
            result['passed'] = False
            result['failures'].append(str(error))
            raise
        finally:
            if moved:
                result['passed'] = False
                result['failures'].append('Installation restoration did not complete')
            result['operations'] = runner.rows
            (evidence / 'install.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--release', type=Path, required=True)
    args = parser.parse_args()
    run(args.evidence, args.release)


if __name__ == '__main__':
    main()
