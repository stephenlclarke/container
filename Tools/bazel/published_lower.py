#!/usr/bin/env python3
"""Import exact published guest and builder layers without rebuilding their sources."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import tarfile

from artifacts.release_asset import cached_fetch, read_lock
from builder_artifact import source_pin
from fork_benchmark import ROOT, digest

LOCKS = Path(__file__).with_name('artifacts') / 'lower-locks'
CACHE = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/published-lower'
SHA = re.compile(r'[0-9a-f]{64}\Z')
Q6FE = '6fe80db1bad6abff5dfa22f02bdf8bc403ad48bc'
GUEST_REPO = 'stephenlclarke/containerization'
BUILDER_REPO = 'stephenlclarke/container-builder-shim'
NAMES = {'guest': 'guest.oci.tar', 'guest-runc': 'guest-runc.oci.tar',
         'builder': 'builder.oci.tar'}
SIDECARS = {'guest': 'qualified-guest-artifacts.json',
            'guest-runc': 'qualified-guest-artifacts.json',
            'builder': 'qualified-builder-artifact.json'}


def source_for(kind: str) -> str:
    if kind == 'builder':
        return source_pin()
    pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    matches = [row['state']['revision'] for row in pins if row['identity'] == 'containerization']
    if len(matches) != 1 or not re.fullmatch(r'[0-9a-f]{40}', matches[0]):
        raise RuntimeError('Containerization has no unique exact source pin')
    return matches[0]


def validate_oci(archive: Path, reference: str, *, builder: bool = False) -> dict:
    script = Path(__file__).with_name('validate-oci-image-layout.py')
    spec = importlib.util.spec_from_file_location('validated_lower_oci', script)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    required = reference.rsplit(':', 1)[-1] if builder else reference
    module.validate_archive(archive, {required})
    with tarfile.open(archive, 'r:') as source:
        index = json.load(source.extractfile('index.json'))
        if len(index['manifests']) != 1:
            raise RuntimeError('Published OCI archive has an ambiguous root')
        descriptor = index['manifests'][0]
        annotations = descriptor.get('annotations', {})
        if (annotations.get('org.opencontainers.image.ref.name') != required
                or (builder and annotations.get('io.containerd.image.name') != reference)):
            raise RuntimeError('Published OCI reference changed')
        while descriptor['mediaType'] == 'application/vnd.oci.image.index.v1+json':
            value = json.load(source.extractfile('blobs/sha256/' + descriptor['digest'][7:]))
            if len(value['manifests']) != 1:
                raise RuntimeError('Published OCI archive has ambiguous platform manifests')
            descriptor = value['manifests'][0]
        if descriptor['mediaType'] != 'application/vnd.oci.image.manifest.v1+json':
            raise RuntimeError('Published OCI image manifest changed')
        platform = descriptor.get('platform', {})
        if platform.get('os') != 'linux' or platform.get('architecture') != 'arm64':
            raise RuntimeError('Published OCI platform changed')
        manifest = json.load(source.extractfile('blobs/sha256/' + descriptor['digest'][7:]))
        if not manifest.get('layers') or (not builder and len(manifest['layers']) != 1):
            raise RuntimeError('Published OCI image layer inventory changed')
        return {'image_digest': descriptor['digest'],
                'layer': manifest['layers'][0]['digest'] if not builder else None}


def guest_binaries(archive: Path, layer: str) -> tuple[dict[str, str], bytes | None]:
    with tarfile.open(archive, 'r:') as image:
        with image.extractfile('blobs/sha256/' + layer[7:]) as stream:
            payload = stream.read()
    result = {}
    runc_bytes = None
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as rootfs:
        for member in rootfs:
            if member.name in {'sbin/vminitd', 'sbin/vmexec', 'sbin/runc'}:
                name = member.name.split('/')[-1]
                if name in result or not member.isfile() or member.mode != 0o755:
                    raise RuntimeError('Published guest executable is ambiguous')
                binary = rootfs.extractfile(member).read()
                result[name] = hashlib.sha256(binary).hexdigest()
                if name == 'runc':
                    runc_bytes = binary
    return result, runc_bytes


def admitted_pair(kind: str, locks: Path, cache: Path) -> tuple[dict, dict, dict]:
    product_lock = read_lock(locks / (kind + '.lock.json'))
    sidecar_lock = read_lock(locks / (('guest' if kind == 'guest-runc' else kind) + '-evidence.lock.json'))
    source = source_for(kind)
    repository = BUILDER_REPO if kind == 'builder' else GUEST_REPO
    if (product_lock['repository'] != repository or sidecar_lock['repository'] != repository
            or product_lock['targetCommit'] != source or sidecar_lock['targetCommit'] != source
            or product_lock['tag'] != sidecar_lock['tag']
            or product_lock['asset'] != NAMES[kind]
            or sidecar_lock['asset'] != SIDECARS[kind]):
        raise RuntimeError('Published lower-layer locks differ from selected source')
    product = cached_fetch(locks / (kind + '.lock.json'), cache)
    sidecar = cached_fetch(locks / (('guest' if kind == 'guest-runc' else kind) + '-evidence.lock.json'), cache)
    if product['releaseId'] != sidecar['releaseId'] or product['assetId'] == sidecar['assetId']:
        raise RuntimeError('Lower artifact and qualification sidecar are not one release')
    if (digest(Path(product['asset'])) != product_lock['sha256']
            or digest(Path(sidecar['asset'])) != sidecar_lock['sha256']):
        raise RuntimeError('Published lower asset bytes differ from pinned locks')
    document = json.loads(Path(sidecar['asset']).read_text())
    if (document.get('schema') != 1 or document.get('source') != source
            or document.get('repository') != repository
            or document.get('tag') != product_lock['tag']
            or document.get('kind') != ('qualified-guest-artifacts' if kind != 'builder' else 'qualified-builder-artifact')
            or document.get('qualification', {}).get('passed') is not True):
        raise RuntimeError('Published lower qualification does not match the selected source')
    if (set(document.get('artifacts', {})) != ({'builder'} if kind == 'builder' else {'guest', 'guest-runc'})
            or not isinstance(document.get('qualification'), dict)):
        raise RuntimeError('Published lower sidecar has an incomplete artifact inventory')
    if kind != 'builder':
        qualification = document['qualification']
        if set(qualification) != {'passed', 'native', 'linux', 'sonar', 'focusedVM'}:
            raise RuntimeError('Guest qualification phase inventory changed')
        for name in ('native', 'linux', 'sonar', 'focusedVM'):
            phase = qualification[name]
            if (not isinstance(phase, dict) or phase.get('source') != source
                    or phase.get('passed') is not True
                    or not SHA.fullmatch(phase.get('evidenceSHA256', ''))):
                raise RuntimeError('Guest qualification evidence is incomplete: ' + name)
        if qualification['focusedVM'].get('guestArchiveSHA256') != document['artifacts']['guest-runc'].get('archive_sha256'):
            raise RuntimeError('Focused VM evidence used a different runc guest')
    return product, sidecar, document


def builder_qualification(document: dict, artifact: dict, locks: Path, cache: Path,
                          release_id: int, asset_ids: set[int]) -> tuple[dict, dict]:
    qualification = document['qualification']
    if (qualification.get('containerSource') != Q6FE
            or not SHA.fullmatch(qualification.get('producerReceiptSHA256', ''))
            or not SHA.fullmatch(qualification.get('acceptanceSHA256', ''))
            or artifact.get('producerReceiptSHA256') != qualification['producerReceiptSHA256']):
        raise RuntimeError('Builder source qualification anchor changed')
    anchor_lock = read_lock(locks / 'builder-anchor.lock.json')
    if (anchor_lock['repository'] != 'stephenlclarke/container'
            or anchor_lock['targetCommit'] != Q6FE
            or anchor_lock['asset'] != 'qualified-container-assets.json'):
        raise RuntimeError('Builder qualification anchor lock changed')
    anchor = cached_fetch(locks / 'builder-anchor.lock.json', cache)
    provenance = json.loads(Path(anchor['asset']).read_text())
    if (provenance.get('qualified_container_source') != Q6FE
            or provenance.get('qualification') != {'target': 'bazel-qualify', 'passed': True}
            or provenance.get('source_receipt_sha256', {}).get('runtime-smoke/builder-artifact.json')
            != qualification['producerReceiptSHA256']
            or provenance.get('source_receipt_sha256', {}).get('acceptance.json')
            != qualification['acceptanceSHA256']
            or provenance.get('assets', {}).get('builder', {}).get('sha256')
            != artifact['archive_sha256']):
        raise RuntimeError('Published Q qualification does not attest the original builder')
    tests_lock = read_lock(locks / 'builder-tests.lock.json')
    if (tests_lock['repository'] != BUILDER_REPO or tests_lock['targetCommit'] != source_pin()
            or tests_lock['tag'] != document['tag']
            or tests_lock['asset'] != 'builder-qualification.tar.gz'
            or tests_lock['sha256'] != qualification.get('testsArchiveSHA256')):
        raise RuntimeError('Builder test evidence lock differs from qualification sidecar')
    tests = cached_fetch(locks / 'builder-tests.lock.json', cache)
    if tests['releaseId'] != release_id or tests['assetId'] in asset_ids:
        raise RuntimeError('Builder test evidence is not in the artifact release')
    expected = artifact.get('qualification_files')
    if not isinstance(expected, dict) or set(expected) != {
            'tests.json', 'toolchain.txt', 'coverage.out', 'coverage-summary.txt'}:
        raise RuntimeError('Builder qualification file inventory changed')
    extracted = {}
    with tarfile.open(tests['asset'], 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) != len(expected) or {row.name for row in members} != set(expected):
            raise RuntimeError('Builder qualification archive inventory changed')
        for row in members:
            if not row.isfile() or row.mode & 0o7000 or row.size > 8 * 1024 * 1024:
                raise RuntimeError('Builder qualification archive has an unsafe member')
            data = archive.extractfile(row).read()
            if hashlib.sha256(data).hexdigest() != expected[row.name]:
                raise RuntimeError('Builder qualification output differs from original receipt')
            extracted[row.name] = data
    return extracted, {'testsAssetId': tests['assetId'], 'testsLockSHA256': digest(locks / 'builder-tests.lock.json'),
                       'testsSHA256': tests_lock['sha256'], 'anchorReleaseId': anchor['releaseId'],
                       'anchorAssetId': anchor['assetId'], 'anchorLockSHA256': digest(locks / 'builder-anchor.lock.json'),
                       'anchorSHA256': anchor_lock['sha256']}


def import_layer(kind: str, evidence: Path, *, locks: Path = LOCKS, cache: Path = CACHE) -> dict:
    if kind not in NAMES or not evidence.is_absolute() or evidence.exists():
        raise RuntimeError('Lower import requires one known kind and a fresh absolute evidence directory')
    product, sidecar, document = admitted_pair(kind, locks, cache)
    artifact = document.get('artifacts', {}).get(kind)
    if (not isinstance(artifact, dict) or artifact.get('archive_sha256') != product['sha256']
            or not SHA.fullmatch(artifact.get('producerReceiptSHA256', ''))
            or not isinstance(artifact.get('identity'), dict)):
        raise RuntimeError('Published lower sidecar differs from archive lock')
    source = source_for(kind)
    reference = ('ghcr.io/stephenlclarke/container-builder-shim/builder:qualification-' + source
                 if kind == 'builder' else
                 'ghcr.io/stephenlclarke/containerization/' +
                 ('vminit-runc:' if kind == 'guest-runc' else 'vminit:') + source)
    if (artifact.get('reference') != reference or artifact.get('identity', {}).get('source') != source):
        raise RuntimeError('Published lower identity or reference changed')
    archive = Path(product['asset'])
    observed = validate_oci(archive, reference, builder=kind == 'builder')
    record = {'schema': 1, 'identity': artifact['identity'], 'reference': reference,
              'archive': str(archive), 'archive_sha256': product['sha256'], 'reused': True}
    builder_evidence = {}
    if kind == 'builder':
        if artifact.get('image_digest') != observed['image_digest']:
            raise RuntimeError('Published builder image digest changed')
        if not isinstance(artifact.get('qualification_files'), dict):
            raise RuntimeError('Published builder qualification inventory is missing')
        test_files, builder_evidence = builder_qualification(
            document, artifact, locks, cache, product['releaseId'], {product['assetId'], sidecar['assetId']})
        record.update(image_digest=observed['image_digest'],
                      qualification_files=artifact['qualification_files'])
    else:
        binaries, runc_bytes = guest_binaries(archive, observed['layer'])
        expected = {'vminitd', 'vmexec', 'runc'} if kind == 'guest-runc' else {'vminitd', 'vmexec'}
        if set(binaries) != expected or binaries != artifact.get('binaries'):
            raise RuntimeError('Published guest executables differ from qualification sidecar')
        record['binaries'] = binaries
        if kind == 'guest-runc':
            pin = artifact['identity'].get('runc')
            if not isinstance(pin, dict) or pin.get('sha256') != binaries['runc']:
                raise RuntimeError('Published guest runc identity changed')
            record['runc_binary'] = str(evidence / 'runc-arm64')
    evidence.mkdir(parents=True, mode=0o700)
    if kind == 'builder':
        tests = evidence / 'tests'
        tests.mkdir(mode=0o700)
        for name, data in test_files.items():
            (tests / name).write_bytes(data)
    elif kind == 'guest-runc':
        binary = evidence / 'runc-arm64'
        binary.write_bytes(runc_bytes)
        binary.chmod(0o755)
    filename = 'builder-artifact.json' if kind == 'builder' else 'guest-artifact.json'
    (evidence / filename).write_text(json.dumps(record, indent=2) + '\n')
    (evidence / 'published-import.json').write_text(json.dumps({
        'schema': 1, 'kind': kind, 'source': source,
        'archiveLockSHA256': digest(locks / (kind + '.lock.json')),
        'sidecarLockSHA256': digest(locks / (('guest' if kind == 'guest-runc' else kind) + '-evidence.lock.json')),
        'archiveReleaseId': product['releaseId'], 'archiveAssetId': product['assetId'],
        'sidecarAssetId': sidecar['assetId'], 'archiveSHA256': product['sha256'],
        **(builder_evidence if kind == 'builder' else {})}, indent=2) + '\n')
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', required=True, choices=sorted(NAMES))
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    import_layer(args.kind, args.evidence)


if __name__ == '__main__':
    main()
