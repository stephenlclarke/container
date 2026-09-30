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

"""Prove that optimized Q products consume only verified compiled lower layers."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
import subprocess

from . import native_evidence, native_layers

LINKS = frozenset(
    '@@+dependencies+swiftpkg_container//:' + name + '.rspm.__impl'
    for name in ('container', 'container-apiserver', 'container-engine',
                 'container-runtime-linux', 'container-network-vmnet',
                 'container-core-images', 'machine-apiserver', 'k8s')
)
ALLOWED_IMPORTED_ACTIONS = frozenset(
    ('FileWrite', 'TemplateExpand', 'ExecutableSymlink', 'SymlinkTree',
     'RepoMappingManifest', 'SourceSymlinkManifest', 'Middleman')
)
REQUIRED_LINK_REPOSITORIES = frozenset({
    '+dependencies+swiftpkg_swift_argument_parser',
    '+dependencies+swiftpkg_containerization',
    '+dependencies+swiftpkg_container_engine_api',
})


def _graph(path: Path) -> dict:
    text = path.read_text()
    start = text.find('\n{')
    if text.lstrip().startswith('{'):
        document = text.lstrip()
    elif start >= 0:
        document = text[start + 1:]
    else:
        raise ValueError('native aquery has no JSON action graph')
    graph, consumed = json.JSONDecoder().raw_decode(document)
    trailing = document[consumed:]
    if (not trailing.startswith('\nINFO:')
            or 'Build completed successfully' not in trailing
            or 'Aquery did NOT complete successfully' in trailing):
        raise ValueError('native aquery did not complete successfully')
    for key in ('actions', 'targets', 'artifacts', 'depSetOfFiles', 'pathFragments'):
        if not isinstance(graph.get(key), list):
            raise ValueError('native aquery lacks configured action inventory')
    return graph


def verify_action_graph(path: Path, admission: dict, loaded: dict[str, str],
                        configuration: str = 'release') -> dict:
    """Reject source compilation of any reached non-Container Swift package.

    The graph includes exec-transition tools. Cache hits are still actions and
    cannot satisfy this check by hiding a source compile behind the disk cache.
    """
    if configuration not in ('release', 'runtime-coverage'):
        raise ValueError('native consumer has an unsupported configuration')
    graph = _graph(path)
    targets = {row['id']: row['label'] for row in graph['targets']}
    fragments = {row['id']: row for row in graph['pathFragments']}
    artifacts = {row['id']: row for row in graph['artifacts']}
    dep_sets = {row['id']: row for row in graph['depSetOfFiles']}
    imported = set(admission['overrides'])
    if set(loaded) != imported or not imported:
        raise ValueError('native action graph has no exact loaded repository set')

    def path_of(fragment_id: int) -> str:
        labels, seen = [], set()
        while fragment_id:
            if fragment_id in seen or fragment_id not in fragments:
                raise ValueError('cyclic or missing native action path fragment')
            seen.add(fragment_id)
            row = fragments[fragment_id]
            labels.append(row['label'])
            fragment_id = row.get('parentId')
        return '/'.join(reversed(labels))

    def input_paths(action: dict) -> set[str]:
        paths, seen = set(), set()
        def visit(identity: int) -> None:
            if identity in seen:
                return
            if identity not in dep_sets:
                raise ValueError('native action input set is missing')
            seen.add(identity)
            row = dep_sets[identity]
            for artifact_id in row.get('directArtifactIds', []):
                if artifact_id not in artifacts:
                    raise ValueError('native action input artifact is missing')
                paths.add(path_of(artifacts[artifact_id]['pathFragmentId']))
            for child in row.get('transitiveDepSetIds', []):
                visit(child)
        for identity in action.get('inputDepSetIds', []):
            visit(identity)
        return paths

    def baseline_coverage_only(action: dict, label: str) -> bool:
        # Bazel's BaselineCoverageAction writes test metadata for every reached
        # rule in coverage mode. It has no inputs or command arguments and does
        # not compile imported source. Bind its one output to its exact owner.
        if configuration != 'runtime-coverage' or action['mnemonic'] != 'BaselineCoverage':
            return False
        if action.get('arguments') or action.get('inputDepSetIds'):
            return False
        output_ids = action.get('outputIds', [])
        if len(output_ids) != 1 or action.get('primaryOutputId') != output_ids[0]:
            return False
        if output_ids[0] not in artifacts or artifacts[output_ids[0]].get('isTreeArtifact') is True:
            return False
        owner = label.removeprefix('@@')
        if owner.count('//') != 1 or owner.count(':') != 1:
            return False
        repository, target = owner.split('//', 1)
        package, name = target.split(':', 1)
        package_parts = package.split('/') if package else []
        if (not name or '/' in name or name in ('.', '..')
                or any(part in ('', '.', '..') for part in package_parts)):
            return False
        output = path_of(artifacts[output_ids[0]]['pathFragmentId'])
        parts = output.split('/')
        if len(parts) < 7 or any(part in ('', '.', '..') for part in parts):
            return False
        if not re.fullmatch(r'darwin_arm64-opt-ST-[0-9a-f]+', parts[1]):
            return False
        return parts == ['bazel-out', parts[1], 'testlogs', 'external',
                         repository, *package_parts, name, 'baseline_coverage.dat']

    links = {}
    archive_inputs = {}
    imported_actions = {}
    for action in graph['actions']:
        label = targets.get(action['targetId'])
        if label is None:
            raise ValueError('native action owner target is missing')
        if label.startswith('@@+dependencies+swiftpkg_') and not label.startswith(
                '@@+dependencies+swiftpkg_container//'):
            canonical = label.split('//', 1)[0].removeprefix('@@')
            if canonical not in imported or (action['mnemonic'] not in ALLOWED_IMPORTED_ACTIONS
                    and not baseline_coverage_only(action, label)):
                raise ValueError('native dependency source action remains reachable: ' + label)
            imported_actions[action['mnemonic']] = imported_actions.get(action['mnemonic'], 0) + 1
        if action['mnemonic'] == 'CppLink' and label in LINKS:
            if label in links:
                raise ValueError('native Container product links more than once')
            inputs = input_paths(action)
            sealed = sorted(path for path in inputs
                            if '/external/+dependencies+swiftpkg_' in '/' + path
                            and '/binary/' in path and path.endswith('.a'))
            if not sealed:
                raise ValueError('native Container link omits imported lower archives')
            repositories = set()
            for entry in sealed:
                parts = Path(entry).parts
                names = [part for part in parts if part.startswith('+dependencies+swiftpkg_')]
                if len(names) != 1 or names[0] not in imported:
                    raise ValueError('native Container link reaches an unverified archive')
                repository = names[0]
                repositories.add(repository)
                relative = Path(*parts[parts.index(repository) + 1:])
                source = Path(admission['overrides'][repository]) / relative
                if (not source.is_file() or source.is_symlink()
                        or not source.resolve(strict=True).is_relative_to(
                            Path(admission['overrides'][repository]).resolve(strict=True))):
                    raise ValueError('native Container link archive escaped its verified repository')
                sha = hashlib.sha256(source.read_bytes()).hexdigest()
                prior = archive_inputs.setdefault(entry, sha)
                if prior != sha:
                    raise ValueError('native Container link archive changed during graph validation')
            links[label] = {
                'importedArchives': len(sealed),
                'repositories': sorted(repositories),
            }
    if set(links) != LINKS:
        raise ValueError('native action graph omitted one of eight Container links')
    if not REQUIRED_LINK_REPOSITORIES.issubset({name for row in links.values()
                                                for name in row['repositories']}):
        raise ValueError('native Container products omit a selected compiled lower layer')
    return {'schema': 1, 'source': admission['source'], 'qualified': False,
            'aquerySHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'actions': len(graph['actions']), 'loadedBUILD': loaded,
            'archiveInputs': archive_inputs,
            'importedActions': imported_actions, 'links': links,
            'layers': {name: native_layers.lower_identity(row)
                       for name, row in admission['layers'].items()}}


def recipe_bindings(admission: dict) -> dict:
    return {name: row['recipeCompatibility'] for name, row in admission['layers'].items()}


def verify_build_and_graph(build_events: Path, action_graph: Path, admission: dict,
                           loaded: dict[str, str], revision: str,
                           configuration: str = 'release') -> dict:
    if configuration not in ('release', 'runtime-coverage'):
        raise ValueError('native consumer has an unsupported configuration')
    flags = ['--config=' + configuration, '--repo_env=GIT_COMMIT=' + revision,
             *native_layers.bazel_flags(admission)]
    build = native_evidence.verify_build_record(
        build_events, ['//:container'], expected_options=flags)
    graph = verify_action_graph(action_graph, admission, loaded, configuration)
    return {'schema': 1, 'passed': True, 'source': revision,
            'configuration': configuration, 'overrides': admission['overrides'],
            'build': build, 'graph': graph,
            'recipeSHA256': admission['recipeSHA256'],
            'recipeCompatibility': recipe_bindings(admission),
            'toolchain': admission['toolchain']}


def retain_compiled_consumer(evidence: Path, admission: dict, output_root: Path,
                             revision: str, configuration: str, *, bazel: Path,
                             env: dict[str, str], build_events: Path) -> dict:
    """Record the configured link closure from the same verified build vector."""
    flags = ['--config=' + configuration, '--repo_env=GIT_COMMIT=' + revision,
             *native_layers.bazel_flags(admission)]
    command = [str(bazel), '--output_user_root=' + str(output_root), 'aquery',
               'deps(//:container)', *flags, '--output=jsonproto']
    result = subprocess.run(command, cwd=native_layers.ROOT, env=env,
                            capture_output=True, text=True, timeout=300)
    graph = evidence / ('fork-' + configuration + '-native-aquery.json')
    graph.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError('Native consumer action inventory failed; see ' + str(graph))
    info = subprocess.check_output([str(bazel), '--output_user_root=' + str(output_root),
                                    'info', 'output_base'], cwd=native_layers.ROOT,
                                   env=env, text=True, timeout=90).splitlines()[-1]
    loaded = native_layers.verify_loaded_repositories(admission, Path(info))
    record = verify_build_and_graph(build_events, graph, admission, loaded,
                                    revision, configuration)
    record['buildEventsSHA256'] = hashlib.sha256(build_events.read_bytes()).hexdigest()
    record['actionGraphSHA256'] = hashlib.sha256(graph.read_bytes()).hexdigest()
    record['actionCommand'] = command
    destination = evidence / ('compiled-consumer.json' if configuration == 'release'
                              else 'coverage-compiled-consumer.json')
    destination.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    return record


def verify_receipt(path: Path, admission: dict, revision: str,
                   configuration: str = 'release', output_base: Path | None = None,
                   *, bazel: Path, output_root: Path) -> dict:
    record = json.loads(path.read_text())
    if (record.get('schema') != 1 or record.get('passed') is not True
            or record.get('source') != revision
            or record.get('configuration') != configuration
            or record.get('overrides') != admission['overrides']
            or record.get('recipeSHA256') != admission['recipeSHA256']
            or record.get('recipeCompatibility') != recipe_bindings(admission)
            or record.get('toolchain') != admission['toolchain']
            or record.get('graph', {}).get('layers') != {
                name: native_layers.lower_identity(row)
                for name, row in admission['layers'].items()}):
        raise ValueError('native compiled consumer receipt differs from current released layers')
    raw = path.parent / ('fork-' + configuration + '-native-aquery.json')
    events = path.parent / ('fork-' + configuration + '.events.json')
    if (hashlib.sha256(raw.read_bytes()).hexdigest() != record.get('actionGraphSHA256')
            or hashlib.sha256(raw.read_bytes()).hexdigest() != record['graph'].get('aquerySHA256')
            or hashlib.sha256(events.read_bytes()).hexdigest() != record.get('buildEventsSHA256')):
        raise ValueError('native compiled consumer action inventory changed')
    expected_command = [str(bazel), '--output_user_root=' + str(output_root), 'aquery',
                        'deps(//:container)', '--config=' + configuration,
                        '--repo_env=GIT_COMMIT=' + revision,
                        *native_layers.bazel_flags(admission), '--output=jsonproto']
    if record.get('actionCommand') != expected_command:
        raise ValueError('native action inventory was not queried with the verified build vector')
    # At build/stage time prove Bazel's live external mapping. A later source
    # test may legitimately remap that shared output base; prepared release
    # admission instead rehashes the originally selected sealed BUILD files.
    loaded = (native_layers.verify_loaded_repositories(admission, output_base)
              if output_base is not None else {
                  name: hashlib.sha256((Path(directory) / 'BUILD.bazel').read_bytes()).hexdigest()
                  for name, directory in admission['overrides'].items()})
    expected = verify_build_and_graph(events, raw, admission, loaded, revision, configuration)
    if any(record.get(key) != expected[key] for key in
           ('build', 'graph', 'overrides', 'recipeCompatibility')):
        raise ValueError('native compiled consumer receipt differs from its raw build')
    for entry, expected in record['graph']['archiveInputs'].items():
        parts = Path(entry).parts
        repos = [part for part in parts if part in admission['overrides']]
        if len(repos) != 1:
            raise ValueError('native compiled consumer archive owner changed')
        repository = repos[0]
        file = Path(admission['overrides'][repository]).joinpath(*parts[parts.index(repository) + 1:])
        if hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError('native compiled consumer archive bytes changed')
    return record


def verify_staged_products(files: list[str], execution: Path, record: dict) -> dict[str, str]:
    """Bind the unsigned eight copied executables to successful BEP output bytes."""
    selected = {}
    for relative in files:
        if (not relative.endswith('.rspm.__impl')
                or '/Contents/Resources/DWARF/' in relative
                or '/external/+dependencies+swiftpkg_container/' not in '/' + relative):
            continue
        name = Path(relative).name.removesuffix('.rspm.__impl')
        if name in selected:
            raise ValueError('native configured executable output is ambiguous')
        record_file = record['build']['files'].get(relative)
        source = execution / relative
        if (record_file is None or not source.is_file() or source.is_symlink()
                or hashlib.sha256(source.read_bytes()).hexdigest() != record_file['sha256']
                or source.stat().st_size != record_file['size']):
            raise ValueError('native staged executable differs from successful Bazel build')
        selected[name] = record_file['sha256']
    if {Path(label.split('//:', 1)[1]).name.removesuffix('.rspm.__impl')
            for label in LINKS} != set(selected):
        raise ValueError('native staged executable inventory omitted a Container link')
    return selected


def unsigned_product_hashes(record: dict) -> dict[str, str]:
    """Select executable bytes, excluding same-named dSYM DWARF files."""
    selected = {}
    for relative, row in record['build']['files'].items():
        if (not relative.endswith('.rspm.__impl')
                or '/Contents/Resources/DWARF/' in relative
                or '/external/+dependencies+swiftpkg_container/' not in '/' + relative):
            continue
        name = Path(relative).name.removesuffix('.rspm.__impl')
        if name in selected:
            raise ValueError('native unsigned product inventory is ambiguous')
        selected[name] = row['sha256']
    if {label.split('//:', 1)[1].removesuffix('.rspm.__impl') for label in LINKS} != set(selected):
        raise ValueError('native unsigned product inventory omitted a Container link')
    return selected
