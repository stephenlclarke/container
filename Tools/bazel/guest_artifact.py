#!/usr/bin/env python3
"""Build the pinned Linux guest once, retain it, and verify every reused archive."""

import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

from fork_benchmark import ROOT, STORAGE, archive, digest, output, install_signal_handlers

SWIFT = Path.home() / 'Library/Developer/Toolchains/swift-6.3-RELEASE.xctoolchain/usr/bin/swift'
MACOS_SDK = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
RETAINED = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/runtime-artifacts/guest'


def file_identity(path: Path) -> str:
    return 'link:' + os.readlink(path) if path.is_symlink() else digest(path)


def snapshot(repository: Path, revision: str, destination: Path) -> dict:
    """Update one owned source view, preserving timestamps of unchanged files."""
    marker = destination / '.container-only-source.json'
    previous = json.loads(marker.read_text()) if marker.exists() else None
    if destination.exists() and previous is None and any(destination.iterdir()):
        raise RuntimeError('Refusing an unowned guest source directory')
    if previous and previous['revision'] == revision:
        for name, expected in previous['files'].items():
            if not (destination / name).exists() or file_identity(destination / name) != expected:
                raise RuntimeError('Guest source snapshot changed: ' + name)
        return previous
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='guest-source-', dir=STORAGE / 'tmp') as temporary:
        staged = Path(temporary)
        archive(repository, revision, staged)
        files = {str(path.relative_to(staged)): file_identity(path)
                 for path in staged.rglob('*') if path.is_file() or path.is_symlink()}
        for name in (previous or {}).get('files', {}):
            if name not in files:
                (destination / name).unlink(missing_ok=True)
        for name, identity in files.items():
            source, target = staged / name, destination / name
            if (target.is_file() or target.is_symlink()) and file_identity(target) == identity:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.unlink(missing_ok=True)
            shutil.copy2(source, target, follow_symlinks=False)
    result = {'revision': revision, 'files': files}
    marker.write_text(json.dumps(result, sort_keys=True) + '\n')
    return result


def rootfs(binary_directory: Path, destination: Path) -> None:
    """Preserve the established init root layout, including pre-proc exe lookup."""
    with destination.open('wb') as stream, gzip.GzipFile(fileobj=stream, mode='wb', filename='', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w|') as tar:
            for name in ['bin', 'sbin', 'dev', 'sys', 'proc', 'proc/self', 'run', 'tmp', 'mnt', 'var']:
                entry = tarfile.TarInfo(name)
                entry.type, entry.mode = tarfile.DIRTYPE, 0o755
                tar.addfile(entry)
            for name in ['vminitd', 'vmexec']:
                binary = binary_directory / name
                entry = tarfile.TarInfo('sbin/' + name)
                entry.mode, entry.size = 0o755, binary.stat().st_size
                with binary.open('rb') as stream:
                    tar.addfile(entry, stream)
            entry = tarfile.TarInfo('proc/self/exe')
            entry.type, entry.mode, entry.linkname = tarfile.SYMTYPE, 0o777, 'sbin/vminitd'
            tar.addfile(entry)


def build(repository: Path, evidence: Path, swift: Path = SWIFT, sdk: Path = MACOS_SDK) -> dict:
    pin = next(pin for pin in json.loads((ROOT / 'Package.resolved').read_text())['pins']
               if pin['identity'] == 'containerization')
    revision = pin['state']['revision']
    if output(['git', '-C', str(repository), 'rev-parse', revision + '^{commit}']) != revision:
        raise RuntimeError('The pinned guest source commit is unavailable')
    base = STORAGE / 'guest'
    base.mkdir(parents=True, exist_ok=True)
    (STORAGE / 'tmp').mkdir(parents=True, exist_ok=True)
    with (base / 'build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        source = base / 'source'
        source_manifest = snapshot(repository, revision, source)
        toolchain = output([str(swift), '--version'])
        if 'Swift version 6.3' not in toolchain or not (sdk / 'SDKSettings.json').is_file():
            raise RuntimeError('The guest requires Swift 6.3 and its compatible macOS manifest SDK')
        environment = dict(os.environ, SDKROOT=str(sdk), GIT_COMMIT=revision, GIT_TAG='',
                           BUILD_TIME=output(['git', '-C', str(repository), 'show', '-s', '--format=%cI', revision]),
                           TMPDIR=str(STORAGE / 'tmp') + '/')
        identity = {'source': revision, 'toolchain': toolchain, 'swiftc_sha256': digest(swift.with_name('swiftc')),
                    'sdk_settings_sha256': digest(sdk / 'SDKSettings.json'),
                    'guest_lock_sha256': digest(source / 'vminitd/Package.resolved'),
                    'static_sdk': 'aarch64-swift-linux-musl', 'configuration': 'release',
                    'build_time': environment['BUILD_TIME'],
                    'packagers': {name: digest(Path(__file__).with_name(name)) for name in
                                 ['guest_artifact.py', 'create-vminit-oci-archive.py', 'validate-oci-image-layout.py']}}
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        retained = RETAINED / revision / key
        receipt = retained / 'artifact.json'
        if receipt.exists():
            record = json.loads(receipt.read_text())
            if record['identity'] != identity or digest(Path(record['archive'])) != record['archive_sha256']:
                raise RuntimeError('Retained guest artifact failed verification; refusing reuse')
            record = dict(record, reused=True)
        else:
            arguments = [str(swift), 'build', '--package-path', str(source / 'vminitd'),
                         '--scratch-path', str(base / 'build'), '--swift-sdk', 'aarch64-swift-linux-musl',
                         '--disable-automatic-resolution', '--configuration', 'release', '--jobs', '6',
                         '-Xswiftc', '-warnings-as-errors', '-Xlinker', '-s']
            print('Building pinned Linux guest; log: ' + str(evidence / 'guest-build.log'), flush=True)
            with (evidence / 'guest-build.log').open('w') as log:
                subprocess.run(arguments, env=environment, stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT, timeout=1800, check=True)
            if snapshot(repository, revision, source) != source_manifest:
                raise RuntimeError('Guest sources changed during the build')
            binaries = base / 'build/release'
            retained.mkdir(parents=True, exist_ok=True)
            layer = retained / 'rootfs.tar.gz'
            rootfs(binaries, layer)
            image = retained / 'guest.oci.tar'
            reference = 'ghcr.io/stephenlclarke/containerization/vminit:' + revision
            subprocess.run([sys.executable, str(Path(__file__).with_name('create-vminit-oci-archive.py')),
                            '--rootfs', str(layer), '--output', str(image), '--reference', reference,
                            '--source-url', pin['location'].removesuffix('.git')], check=True, timeout=120)
            subprocess.run([sys.executable, str(Path(__file__).with_name('validate-oci-image-layout.py')),
                            str(image)], check=True, timeout=120, stdout=subprocess.DEVNULL)
            record = {'schema': 1, 'identity': identity, 'reference': reference,
                      'archive': str(image), 'archive_sha256': digest(image), 'reused': False,
                      'binaries': {name: digest(binaries / name) for name in ['vminitd', 'vmexec']}}
            receipt.write_text(json.dumps(record, indent=2) + '\n')
        (evidence / 'guest-artifact.json').write_text(json.dumps(record, indent=2) + '\n')
        return record


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, default=Path.home() / 'github/containerization')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--swift', type=Path, default=SWIFT)
    parser.add_argument('--sdk', type=Path, default=MACOS_SDK)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    build(args.repository, args.evidence, args.swift, args.sdk)
    print('Guest artifact: ' + str(args.evidence / 'guest-artifact.json'))


if __name__ == '__main__':
    main()
