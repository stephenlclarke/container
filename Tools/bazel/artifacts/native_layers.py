#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Verify and import the published native layers built in this Container graph.

No caller-selected repository path is admitted. Overrides are formed solely
from exact published locks and extracted, hash-checked package directories.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile

from . import native_format
from .release_asset import cached_fetch, read_lock

ROOT = Path(__file__).resolve().parents[3]
LOCKS = Path(__file__).with_name('native-locks')
CACHE = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/native-layers'
GROUPS = ('foundation', 'containerization', 'engine-api')
ALL_GROUPS = ('argument-parser', *GROUPS)
GROUP_OWNER = {'argument-parser': 'stephenlclarke/container',
               'foundation': 'stephenlclarke/container',
               'containerization': 'stephenlclarke/containerization',
               'engine-api': 'stephenlclarke/container-engine-api'}
GROUP_PIN = {'argument-parser': 'swift-argument-parser',
             'containerization': 'containerization',
             'engine-api': 'container-engine-api'}
UPPER = {'container', 'containerization', 'container-engine-api',
         'swift-argument-parser', 'swift-docc-plugin', 'swift-docc-symbolkit'}
LOWER = {'argument-parser': (), 'foundation': ('argument-parser',),
         'containerization': ('argument-parser', 'foundation'),
         'engine-api': ('argument-parser', 'foundation')}
SHA = re.compile(r'[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
REPO = re.compile(r'swiftpkg_[a-z0-9_]+\Z')


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pin_records(root: Path = ROOT) -> dict[str, dict]:
    rows = json.loads((root / 'Package.resolved').read_text())['pins']
    records = {row['identity']: row for row in rows}
    if (len(records) != len(rows) or any(row.get('kind') != 'remoteSourceControl'
            or not isinstance(row.get('location'), str)
            or not COMMIT.fullmatch(row.get('state', {}).get('revision', ''))
            for row in rows)):
        raise ValueError('native layer source pins are incomplete or ambiguous')
    return records


def group_pins(group: str, records: dict[str, dict]) -> dict[str, dict]:
    if group == 'foundation':
        return {key: value for key, value in records.items() if key not in UPPER}
    return {GROUP_PIN[group]: records[GROUP_PIN[group]]}


def lower_identity(receipt: dict) -> dict:
    return {key: receipt[key] for key in ('archiveSHA256', 'evidenceSHA256',
            'proofSHA256', 'releaseId', 'assetId', 'evidenceAssetId', 'proofAssetId', 'lockSHA256',
            'producerCommit', 'sourcePins')}


def recipe(root: Path = ROOT) -> dict[str, str]:
    # Lock files deliberately remain outside this identity: an upper lock is
    # never an input to its own producer recipe. Lower identities are explicit.
    names = ('Package.swift', 'MODULE.bazel', 'MODULE.bazel.lock', '.bazelrc',
             '.bazelversion', 'BUILD.bazel', 'Tools/bazel/dependencies.bzl',
             'Tools/bazel/layers.bzl', 'Tools/bazel/layer_build.bzl',
             'Tools/bazel/test_inputs.bzl', 'Tools/bazel/artifacts/BUILD.bazel',
             'Tools/bazel/artifacts/release_asset.py',
             'Tools/bazel/artifacts/native_layers.py',
             'Tools/bazel/artifacts/native_format.py',
             'Tools/bazel/artifacts/foundation_import.bzl',
             'Tools/bazel/artifacts/compiled_outputs.bzl',
             'Tools/bazel/run.sh', 'Tools/bazel/bazel_environment.py')
    paths = [root / name for name in names]
    paths += sorted((root / 'Tools/bazel').glob('*.patch'))
    paths += sorted((root / 'Tools/bazel/artifacts').glob('native_*.py'))
    return {str(path.relative_to(root)): digest(path) for path in paths}


def toolchain(root: Path = ROOT) -> dict[str, str]:
    def output(*args: str) -> str:
        return subprocess.check_output(args, text=True, timeout=30).strip()
    compiler = Path(output('/usr/bin/xcrun', '-f', 'swiftc'))
    sdk = Path(output('/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'))
    return {'swiftcSHA256': digest(compiler),
            'swiftVersion': output(str(compiler), '--version'),
            'sdkSettingsSHA256': digest(sdk / 'SDKSettings.json'),
            'sdkVersion': output('/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'),
            'xcodeVersion': output('/usr/bin/xcodebuild', '-version'),
            'bazelVersion': (root / '.bazelversion').read_text().strip(),
            'hostMachine': platform.machine(),
            'platform': platform.system()}


def repo_name(identity: str) -> str:
    value = 'swiftpkg_' + identity.replace('-', '_').replace('.', '_')
    if not REPO.fullmatch(value):
        raise ValueError('native package has an unsupported repository name')
    return value


def _release_pair(name: str, locks: Path, cache: Path) -> tuple[dict, dict, dict, dict]:
    archive_path = locks / f'{name}.archive.lock.json'
    evidence_path = locks / f'{name}.evidence.lock.json'
    proof_path = locks / f'{name}.proof.lock.json'
    product_lock, evidence_lock, proof_lock = (read_lock(path) for path in
                                               (archive_path, evidence_path, proof_path))
    if (len({row['repository'] for row in (product_lock, evidence_lock, proof_lock)}) != 1
            or len({row['tag'] for row in (product_lock, evidence_lock, proof_lock)}) != 1
            or len({row['targetCommit'] for row in (product_lock, evidence_lock, proof_lock)}) != 1
            or len({row['asset'] for row in (product_lock, evidence_lock, proof_lock)}) != 3):
        raise ValueError('native layer archive, evidence and proof are not one release')
    product = cached_fetch(archive_path, cache / name / 'archive')
    evidence = cached_fetch(evidence_path, cache / name / 'evidence')
    proof = cached_fetch(proof_path, cache / name / 'proof')
    if (len({row['releaseId'] for row in (product, evidence, proof)}) != 1
            or len({row['assetId'] for row in (product, evidence, proof)}) != 3
            or digest(Path(product['asset'])) != product_lock['sha256']
            or digest(Path(evidence['asset'])) != evidence_lock['sha256']
            or digest(Path(proof['asset'])) != proof_lock['sha256']):
        raise ValueError('native layer published asset triple changed')
    return product, evidence, proof, {'archive': product_lock, 'evidence': evidence_lock,
                               'proof': proof_lock,
                               'lockSHA256': {key: digest(path) for key, path in
                                              [('archive', archive_path), ('evidence', evidence_path),
                                               ('proof', proof_path)]}}


def _safe_extract(archive: Path, manifest: dict, group: str, destination: Path) -> dict[str, Path]:
    if destination.exists() or destination.is_symlink():
        raise ValueError('native layer extraction must use a fresh directory')
    packages = manifest['packages']
    if not isinstance(packages, dict) or not packages:
        raise ValueError('native layer package inventory is empty')
    expected = {f'{group}/{row["repository"]}/BUILD.bazel' for row in packages.values()}
    destination.mkdir(parents=True, mode=0o700)
    with tarfile.open(archive, 'r:gz') as source:
        for item in source:
            components = item.name.split('/')
            if (not item.isfile() or item.issym() or item.islnk()
                    or len(components) < 3 or components[0] != group
                    or any(value in ('', '.', '..') for value in components)
                    or item.name == f'{group}/layer.json'):
                if item.name == f'{group}/layer.json' and item.isfile():
                    continue
                raise ValueError('native layer archive has an unsafe member')
            target = destination.joinpath(*components[1:])
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if target.exists():
                raise ValueError('native layer archive member is duplicated')
            with source.extractfile(item) as stream:
                data = stream.read()
            if hashlib.sha256(data).hexdigest() != manifest['files'][item.name]:
                raise ValueError('native layer extraction bytes changed')
            target.write_bytes(data)
            target.chmod(item.mode)
    found = {name: destination / row['repository'] for name, row in packages.items()}
    if (not expected.issubset(manifest['files'])
            or any(not directory.is_dir() or directory.is_symlink()
                   or not (directory / 'BUILD.bazel').is_file() for directory in found.values())):
        raise ValueError('native layer lacks a compiled package BUILD')
    return found


def _private_cache(cache: Path) -> None:
    home = Path.home()
    if not cache.is_relative_to(home):
        raise ValueError('native cache must remain in the current user home')
    if home.is_symlink() or home.stat().st_uid != os.getuid():
        raise ValueError('native home is not an owned directory')
    node = home
    for part in cache.relative_to(home).parts:
        node = node / part
        if node.is_symlink():
            raise ValueError('native cache ancestor is a symlink')
        if node.exists() and (not node.is_dir() or node.stat().st_uid != os.getuid()):
            raise ValueError('native cache ancestor is not owned by this user')


def _external_directory(root: Path, repository: str) -> Path:
    # The pinned Q Bazel output root is part of its existing launcher contract.
    output = subprocess.check_output([str(root / 'Tools/bazel/run.sh'), 'info', 'output_base'],
                                     cwd=root, text=True, timeout=90).splitlines()[-1]
    location = Path(output)
    from fork_benchmark import STORAGE
    if not location.is_relative_to(STORAGE / 'output'):
        raise ValueError('Q Bazel output base escaped its enrolled storage')
    candidate = location / 'external' / ('+dependencies+' + repository)
    if not (candidate / 'BUILD.bazel').is_file():
        raise ValueError('Q generated package repository is unavailable or ambiguous')
    return candidate


def import_layers(root: Path = ROOT, locks: Path = LOCKS, cache: Path = CACHE,
                  groups: tuple[str, ...] = GROUPS) -> dict:
    if groups not in ((), ('foundation',), GROUPS):
        raise ValueError('native layer import requires an exact lower-chain prefix')
    records = pin_records(root)
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('native compiled layers require Apple silicon macOS')
    current_toolchain = toolchain(root)
    if current_toolchain['bazelVersion'] != '8.8.0':
        raise ValueError('native compiled layers require pinned Bazel 8.8.0')
    _private_cache(cache)
    packages, receipts = {}, {}
    for group in ('argument-parser', *groups):
        _private_cache(cache / group)
        product, evidence, proof, pair = _release_pair(group, locks, cache)
        if (pair['archive']['repository'] != GROUP_OWNER[group]
                or pair['archive']['asset'] != f'{group}-native-darwin-arm64-opt.tar.gz'
                or pair['evidence']['asset'] != f'{group}-native-evidence.json'
                or pair['proof']['asset'] != f'{group}-native-proof.tar.gz'):
            raise ValueError('published native layer owner or asset name changed')
        observed = native_format.inspect(Path(product['asset']), pair['archive']['sha256'])
        manifest = observed['manifest']
        selected = group_pins(group, records)
        if (manifest.get('group') != group or manifest.get('graph') != 'container-native'
                or manifest.get('profile') != 'native'
                or manifest.get('configuration') != 'opt'
                or manifest.get('platform') != 'darwin-arm64'
                or manifest.get('developmentProof') is not False
                or manifest.get('sourcePins') != selected
                or manifest.get('recipeSHA256') != recipe(root)
                or manifest.get('toolchain') != current_toolchain
                or pair['archive']['targetCommit'] !=
                (records[GROUP_PIN[group]]['state']['revision']
                 if group not in ('argument-parser', 'foundation') else manifest.get('producerCommit'))
                or pair['evidence']['targetCommit'] != pair['archive']['targetCommit']):
            raise ValueError('published native layer differs from selected Q source graph')
        lower = {name: lower_identity(receipts[name]) for name in LOWER[group]}
        if manifest.get('lower') != lower:
            raise ValueError('native layer lower archive chain differs')
        sidecar = json.loads(Path(evidence['asset']).read_text())
        if (sidecar.get('schema') != 1 or sidecar.get('group') != group
                or sidecar.get('archiveSHA256') != pair['archive']['sha256']
                or sidecar.get('source') != manifest['producerCommit']
                or sidecar.get('sourcePins') != selected
                or sidecar.get('recipeSHA256') != manifest['recipeSHA256']
                or sidecar.get('toolchain') != current_toolchain
                or sidecar.get('lower') != lower
                or sidecar.get('manifestSHA256') != hashlib.sha256(
                    (json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest()
                or sidecar.get('passed') is not True
                or sidecar.get('developmentProof') is not False):
            raise ValueError('native layer publication has no matching passed evidence')
        if (sidecar.get('proofBundle', {}).get('asset') != pair['proof']['asset']
                or sidecar['proofBundle'].get('sha256') != pair['proof']['sha256']):
            raise ValueError('native layer portable proof asset differs from publication')
        from .native_producer import verify_proof_bundle
        verify_proof_bundle(Path(proof['asset']), sidecar)
        selected_outputs = manifest.get('payloadOutputs')
        source_build = sidecar.get('producerBuild')
        qualification = sidecar.get('qualification')
        if (not isinstance(selected_outputs, dict) or not selected_outputs
                or set(selected_outputs) != {name for name in manifest['files'] if '/binary/' in name}
                or not isinstance(source_build, dict)
                or not isinstance(source_build.get('files'), dict)
                or not isinstance(qualification, dict)
                or qualification.get('passed') is not True
                or qualification.get('group') != group
                or qualification.get('source') != manifest['producerCommit']
                or sidecar.get('qualificationSHA256') != qualification.get('qualificationSHA256')
                or any(source_build['files'].get(configured, {}).get('sha256') != manifest['files'][member]
                       for member, configured in selected_outputs.items())):
            raise ValueError('native layer binary or source-test evidence is incomplete')
        destination = cache / group / pair['archive']['sha256'] / 'packages'
        _private_cache(destination)
        if not destination.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='native-', dir=destination.parent) as temporary:
                staged = Path(temporary) / 'packages'
                _safe_extract(Path(product['asset']), manifest, group, staged)
                staged.rename(destination)
        # Rehash the complete extracted inventory on every use, including
        # offline reuse. Extra files can otherwise be reached by BUILD globs.
        expected = {relative.removeprefix(group + '/') for relative in manifest['files']}
        actual = set()
        for path in destination.rglob('*'):
            if path.is_symlink() or path.stat().st_uid != os.getuid():
                raise ValueError('native cached package has an unsafe file or directory')
            if path.is_file():
                actual.add(str(path.relative_to(destination)))
            elif not path.is_dir():
                raise ValueError('native cached package has an unexpected file type')
        if actual != expected:
            raise ValueError('native cached package file inventory changed')
        for relative in expected:
            file = destination / relative
            if (file.is_symlink() or not file.is_file()
                    or not file.resolve(strict=True).is_relative_to(destination.resolve(strict=True))
                    or digest(file) != manifest['files'][f'{group}/{relative}']
                    or (file.stat().st_mode & 0o7777) != (
                        0o755 if relative.endswith('/binary/SmithyCodegenCLI.rspm.__impl')
                        else 0o644)):
                raise ValueError('native cached package differs from published archive')
        for name, row in manifest['packages'].items():
            if (name not in selected or row.get('sourceCommit') != selected[name]['state']['revision']
                    or row.get('sourceLocation') != selected[name]['location']
                    or row.get('repository') != repo_name(name) or name in packages
                    or not SHA.fullmatch(row.get('generatedBuildSHA256', ''))):
                raise ValueError('native layer package source, location or ownership changed')
            packages[name] = destination / row['repository']
        required = {'argument-parser': 'swift-argument-parser',
                    'foundation': 'swift-log',
                    'containerization': 'containerization',
                    'engine-api': 'container-engine-api'}[group]
        if required not in manifest['packages']:
            raise ValueError('native layer lacks its required source package')
        receipts[group] = {'archiveSHA256': pair['archive']['sha256'],
                           'evidenceSHA256': pair['evidence']['sha256'],
                           'proofSHA256': pair['proof']['sha256'],
                           'assetId': product['assetId'], 'evidenceAssetId': evidence['assetId'],
                           'proofAssetId': proof['assetId'],
                           'lockSHA256': pair['lockSHA256'], 'sourcePins': selected,
                           'releaseId': product['releaseId'], 'lower': lower,
                           'producerCommit': manifest['producerCommit']}
    expected = set(records) - {'container', 'swift-docc-plugin', 'swift-docc-symbolkit'}
    # Container itself remains source-built. Every reached dependency must be
    # either imported or explicitly absent from the production closure proof.
    if groups == GROUPS and not {'swift-argument-parser', 'containerization', 'container-engine-api'}.issubset(packages):
        raise ValueError('native imported layer closure is missing a required package')
    overrides = {f'+dependencies+{repo_name(name)}': str(path.resolve(strict=True))
                 for name, path in packages.items()}
    cache_root = cache.resolve(strict=True)
    if len(overrides) != len(packages) or not all(
            Path(path).resolve(strict=True).is_relative_to(cache_root)
            for path in overrides.values()):
        raise ValueError('native override vector escaped verified archive cache')
    return {'schema': 1, 'source': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'],
                                                          text=True, timeout=20).strip(),
            'overrides': overrides, 'layers': receipts,
            'recipeSHA256': recipe(root), 'toolchain': current_toolchain,
            'expectedUnimportedPins': sorted(expected - set(packages))}


def bazel_flags(admission: dict) -> list[str]:
    vector = admission['overrides']
    if not vector or any(not key.startswith('+dependencies+swiftpkg_')
                         or not Path(value).is_absolute() for key, value in vector.items()):
        raise ValueError('native production has no verified canonical overrides')
    return [f'--override_repository={name}={vector[name]}' for name in sorted(vector)]


def verify_loaded_repositories(admission: dict, output_base: Path) -> dict[str, str]:
    loaded = {}
    for canonical, selected in admission['overrides'].items():
        name = canonical.removeprefix('+dependencies+')
        target = output_base / 'external' / canonical
        selected_path = Path(selected)
        if (target.resolve(strict=True) != selected_path.resolve(strict=True)
                or (target / 'BUILD.bazel').resolve(strict=True) !=
                (selected_path / 'BUILD.bazel').resolve(strict=True)
                or digest(target / 'BUILD.bazel') != digest(selected_path / 'BUILD.bazel')):
            raise ValueError('Bazel ignored or redirected a verified canonical repository override: ' + name)
        loaded[canonical] = digest(target / 'BUILD.bazel')
    return loaded
