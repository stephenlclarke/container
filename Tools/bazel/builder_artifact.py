#!/usr/bin/env python3
"""Qualify and package the pinned builder source as an immutable local OCI archive."""

import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

from fork_benchmark import PAIRS, ROOT, STORAGE, Runner, digest, install_signal_handlers
from guest_artifact import snapshot

RETAINED = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/runtime-artifacts/builder'


def source_pin() -> str:
    revision = PAIRS['container-builder-shim']['fork']
    version = re.search(r'let builderShimVersion = .*?\?\? "([^"]+)"', (ROOT / 'Package.swift').read_text())
    if not version or not version[1].endswith('-' + revision[:12]):
        raise RuntimeError('Builder source pin does not match the container manifest')
    return revision


def build(evidence: Path, context: str, repository: Path) -> dict:
    evidence.mkdir(parents=True, exist_ok=False)
    base = STORAGE / 'builder'
    base.mkdir(parents=True, exist_ok=True)
    (STORAGE / 'tmp').mkdir(parents=True, exist_ok=True)
    runner = Runner(evidence, base)
    with (base / 'build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        revision = source_pin()
        source = base / 'source'
        source_identity = snapshot(repository, revision, source)
        dockerfile = (source / 'Dockerfile').read_text()
        build_image = re.search(r'^ARG BUILD_IMAGE=(\S+@sha256:[0-9a-f]{64})$', dockerfile, re.M)
        final_image = re.search(r'^ARG FINAL_IMAGE=(\S+@sha256:[0-9a-f]{64})$', dockerfile, re.M)
        if not build_image or not final_image:
            raise RuntimeError('Both builder base images must be pinned by digest')
        identity = {'source': revision, 'build_image': build_image[1], 'final_image': final_image[1],
                    'platform': 'linux/arm64', 'files': source_identity['files'],
                    'workflow': {name: digest(Path(__file__).with_name(name)) for name in
                                 ['builder_artifact.py', 'builder-test.Dockerfile', 'validate-oci-image-layout.py']}}
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        retained = RETAINED / revision / key
        receipt = retained / 'artifact.json'
        if receipt.exists():
            record = json.loads(receipt.read_text())
            if record['identity'] != identity or digest(Path(record['archive'])) != record['archive_sha256']:
                raise RuntimeError('Retained builder artifact failed verification; refusing reuse')
            for name, sha in record['qualification_files'].items():
                if digest(retained / 'tests' / name) != sha:
                    raise RuntimeError('Retained builder qualification evidence changed')
            record = dict(record, reused=True)
        else:
            retained.mkdir(parents=True, exist_ok=True)
            tests = retained / 'tests'
            docker = ['docker', '--context', context, 'buildx', 'build', '--platform', 'linux/arm64', '--provenance=false']
            row = runner.run('builder', 'fork', 'tests', 0, docker + [
                '--file', str(Path(__file__).with_name('builder-test.Dockerfile')),
                '--build-arg', 'BUILD_IMAGE=' + build_image[1],
                '--output', 'type=local,dest=' + str(tests), str(source)], ROOT, timeout=1800)
            if row['status']:
                raise RuntimeError('Builder qualification failed: ' + row['log'])
            archive = retained / 'builder.oci.tar'
            reference = 'ghcr.io/stephenlclarke/container-builder-shim/builder:qualification-' + revision
            row = runner.run('builder', 'fork', 'image', 0, docker + [
                '--build-arg', 'GIT_TAG=' + revision,
                '--tag', reference, '--output', 'type=oci,dest=' + str(archive), str(source)], ROOT, timeout=1800)
            if row['status']:
                raise RuntimeError('Builder image build failed: ' + row['log'])
            subprocess.run([sys.executable, str(Path(__file__).with_name('validate-oci-image-layout.py')),
                            str(archive)], check=True, timeout=120, stdout=subprocess.DEVNULL)
            with tarfile.open(archive) as image:
                index = json.load(image.extractfile('index.json'))
            if len(index['manifests']) != 1:
                raise RuntimeError('Expected one arm64 builder manifest')
            if snapshot(repository, revision, source) != source_identity:
                raise RuntimeError('Builder sources changed during verification')
            record = {'schema': 1, 'identity': identity, 'archive': str(archive),
                      'archive_sha256': digest(archive), 'reference': reference,
                      'image_digest': index['manifests'][0]['digest'], 'reused': False,
                      'qualification_files': {str(p.relative_to(tests)): digest(p) for p in tests.rglob('*') if p.is_file()}}
            receipt.write_text(json.dumps(record, indent=2) + '\n')
        (evidence / 'builder-artifact.json').write_text(json.dumps(record, indent=2) + '\n')
        shutil.copytree(retained / 'tests', evidence / 'tests')
        return record


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--context', default='colima')
    parser.add_argument('--repository', type=Path, default=Path(PAIRS['container-builder-shim']['repo']))
    args = parser.parse_args()
    build(args.evidence, args.context, args.repository)


if __name__ == '__main__':
    main()
