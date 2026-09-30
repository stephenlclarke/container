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

"""Produce a Q-graph compiled lower layer and stage a guarded release plan."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tarfile

from . import native_evidence, native_format, native_layers
from .release_asset import fetch, publish_assets

ROOT = native_layers.ROOT
GROUPS = ('argument-parser', *native_layers.GROUPS)


def _source_state(root: Path) -> dict:
    commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'],
                                     text=True, timeout=20).strip()
    dirty = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'],
                                    text=True, timeout=20).strip()
    return {'commit': commit, 'dirty': bool(dirty), 'recipe': native_layers.recipe(root),
            'pins': native_layers.pin_records(root), 'toolchain': native_layers.toolchain(root)}


def _run_bazel(root: Path, action: str, flags: list[str], target: str | list[str],
               output: Path) -> tuple[str, Path | None]:
    targets = [target] if isinstance(target, str) else target
    invocation = [str(root / 'Tools/bazel/run.sh'), action, *targets, *flags]
    result = subprocess.run(invocation, cwd=root, capture_output=True, text=True, timeout=3600)
    output.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'Q native {action} failed with status {result.returncode}; see {output}')
    matches = re.findall(r'^Evidence: (/.+\.log)$', result.stdout, re.M)
    if len(matches) != 1:
        raise ValueError('Q native Bazel invocation lacks one retained evidence log')
    log = Path(matches[0])
    if not log.is_file():
        raise ValueError('Q native Bazel retained log is absent')
    return result.stdout, log


def _selected_bazel_outputs(lines: list[str], binaries: dict[str, dict[str, bytes]],
                            identities: dict[str, dict], execution: Path) -> dict[str, Path]:
    selected = {}
    matched = {name: set() for name in binaries}
    for line in lines:
        relative = Path(line.strip())
        if not relative.parts or relative.parts[0] != 'bazel-out':
            continue
        repository = next((part.removeprefix('+dependencies+') for part in relative.parts
                           if part.startswith('+dependencies+swiftpkg_')), None)
        if repository not in binaries:
            continue
        name = relative.name
        key = 'binary/' + (name.removesuffix('.lo') + '.a' if name.endswith('.lo') else name)
        if key not in binaries[repository] or identities[repository]['configured'][key] != relative.parts[1]:
            continue
        actual = (execution / relative).resolve(strict=True)
        if hashlib.sha256(actual.read_bytes()).digest() != hashlib.sha256(binaries[repository][key]).digest():
            raise ValueError('selected configured output changed before native sealing')
        if key in matched[repository] or line in selected:
            raise ValueError('selected native configured output is ambiguous')
        matched[repository].add(key)
        selected[line] = actual
    if any(matched[name] != set(members) for name, members in binaries.items()):
        raise ValueError('native layer configured outputs differ from sealed binaries')
    return selected


def produce(group: str, output: Path, *, development_proof: bool = False,
            root: Path = ROOT) -> dict:
    if group not in GROUPS or not output.is_absolute() or output.exists():
        raise ValueError('native producer requires one group and a fresh absolute output')
    before = _source_state(root)
    nonpublishable = development_proof or before['dirty']
    if before['dirty'] and not development_proof:
        raise ValueError('publishable native producer requires a clean Q checkout')
    lower_groups = () if group == 'foundation' else ('foundation',)
    lower = ({'layers': {}, 'overrides': {}} if group == 'argument-parser' else
             native_layers.import_layers(root, groups=lower_groups))
    output.mkdir(parents=True, mode=0o700)
    (output / 'source-before.json').write_text(json.dumps(before, indent=2, sort_keys=True) + '\n')
    repository_flags = ([] if group == 'argument-parser' else native_layers.bazel_flags(lower))
    aspect = group.replace('-', '_') + '_outputs'
    build_flags = (['--config=release', '--macos_minimum_os=12.0']
                   if group == 'argument-parser' else
                   ['--config=release',
                    f'--aspects=//Tools/bazel/artifacts:compiled_outputs.bzl%{aspect}',
                    '--output_groups=layer_compiled', *repository_flags])
    argument_targets = [
        '@swiftpkg_swift_argument_parser//:ArgumentParser.rspm.__impl',
        '@swiftpkg_swift_argument_parser//:ArgumentParserToolInfo.rspm.__impl',
    ]
    build_target = argument_targets if group == 'argument-parser' else '//:container-executables'
    _, build_log = _run_bazel(root, 'build', build_flags, build_target,
                              output / 'source-build.log')
    # The wrapper transcript and Bazel's raw retained log have distinct bytes.
    # Keep both and bind the raw source-build record at publication time.
    raw_build_log = output / 'source-build.raw.log'
    shutil.copy2(build_log, raw_build_log)
    raw_events = build_log.with_suffix('.events.json')
    if not raw_events.is_file():
        raise ValueError('native layer source build lacks its raw BEP')
    events = output / 'source-build.events.json'
    shutil.copy2(raw_events, events)
    for suffix in ('.source.txt', '.diff', '.inputs.sha256'):
        raw = raw_events.with_name(raw_events.name.removesuffix('.events.json') + suffix)
        if not raw.is_file():
            raise ValueError('native layer source build lacks its source snapshot')
        shutil.copy2(raw, output / ('source-build' + suffix))
    query_target = ('deps(set(' + ' '.join(argument_targets) + '))'
                    if group == 'argument-parser' else 'deps(//:container-executables)')
    listed, query_log = _run_bazel(root, 'cquery',
                                    ['--config=release',
                                     *(['--macos_minimum_os=12.0'] if group == 'argument-parser' else []),
                                     *repository_flags,
                                     '--output=files'],
                                    query_target, output / 'configured-outputs.log')
    raw_query_log = output / 'configured-outputs.raw.log'
    shutil.copy2(query_log, raw_query_log)
    base = Path(subprocess.check_output([str(root / 'Tools/bazel/run.sh'), 'info', 'output_base'],
                                        cwd=root, text=True, timeout=90).splitlines()[-1])
    execution = Path(subprocess.check_output([str(root / 'Tools/bazel/run.sh'), 'info', 'execution_root'],
                                             cwd=root, text=True, timeout=90).splitlines()[-1])
    loaded = native_layers.verify_loaded_repositories(lower, base)
    selected = ({'swift-argument-parser': before['pins']['swift-argument-parser']}
                if group == 'argument-parser' else native_layers.group_pins(group, before['pins']))
    allowed = {native_layers.repo_name(name): name for name in selected}
    output_lines = listed.splitlines()
    if group == 'argument-parser':
        # The direct module targets above produce the minimum-macOS-12
        # artifacts here. The dependency query also enumerates a tool
        # transition variant that those targets did not build.
        output_lines = [line for line in output_lines
                        if '/darwin_arm64-opt/bin/' in line]
    binaries, identities = native_format.artifact_map(output_lines, execution, base, allowed)
    selected_outputs = _selected_bazel_outputs(output_lines, binaries, identities, execution)
    aspect_label = (None if group == 'argument-parser' else
                    '//Tools/bazel/artifacts:compiled_outputs.bzl%' + aspect)
    build_proof = native_evidence.verify_build(events, build_target if isinstance(build_target, list)
                                               else [build_target], aspect_label, selected_outputs,
                                               expected_options=build_flags)
    configured_members = {}
    for configured in selected_outputs:
        relative = Path(configured)
        repository = next(part.removeprefix('+dependencies+') for part in relative.parts
                          if part.startswith('+dependencies+swiftpkg_'))
        filename = relative.name
        key = 'binary/' + (filename.removesuffix('.lo') + '.a'
                           if filename.endswith('.lo') else filename)
        member = f'{group}/{repository}/{key}'
        if member in configured_members:
            raise ValueError('one sealed member has multiple configured outputs')
        configured_members[member] = configured
    source_proof = (None if nonpublishable else native_evidence.verify_source_snapshot(
        events, before['commit'], root,
        {**before['recipe'], 'Package.resolved': native_layers.digest(root / 'Package.resolved')}))
    members, packages = {}, {}
    for repository, identity in identities.items():
        if not binaries[repository]:
            continue
        name = allowed[repository]
        source = base / 'external' / ('+dependencies+' + repository)
        generated_build_sha = native_layers.digest(source / 'BUILD.bazel')
        overlay = native_format.package_overlay(repository, source, binaries[repository], identity)
        prefix = group + '/' + repository + '/'
        members.update({prefix + name: content for name, content in overlay.items()})
        packages[name] = {'sourceCommit': selected[name]['state']['revision'],
                          'sourceLocation': selected[name]['location'],
                          'repository': repository,
                          'generatedBuildSHA256': generated_build_sha,
                          'swiftTargets': sorted(identity['swift']),
                          'cTargets': sorted(identity['cc']),
                          'executables': sorted(identity['executables']),
                          'configuredOutputs': identity['configured']}
    required = {'argument-parser': 'swift-argument-parser',
                'foundation': 'swift-log', 'containerization': 'containerization',
                'engine-api': 'container-engine-api'}[group]
    if required not in packages or not members:
        raise ValueError('Q configured closure omitted the required native package')
    after = _source_state(root)
    (output / 'source-after.json').write_text(json.dumps(after, indent=2, sort_keys=True) + '\n')
    if after != before:
        raise ValueError('Q source changed during native layer production')
    low = {name: native_layers.lower_identity(lower['layers'][name])
           for name in native_layers.LOWER[group]}
    manifest = {'schema': 1, 'group': group, 'profile': 'native',
                'graph': 'container-native', 'configuration': 'opt',
                'platform': 'darwin-arm64', 'developmentProof': nonpublishable,
                'minimumMacOS': '12.0' if group == 'argument-parser' else '15.0',
                'producerCommit': before['commit'], 'sourcePins': selected,
                'recipeSHA256': before['recipe'], 'toolchain': before['toolchain'],
                'lower': low, 'packages': packages,
                'payloadOutputs': configured_members,
                'files': {name: hashlib.sha256(content).hexdigest()
                          for name, content in members.items()}}
    if set(configured_members) != {name for name in members if '/binary/' in name}:
        raise ValueError('native payload does not exactly match successful build outputs')
    archive = output / f'{group}-native-darwin-arm64-opt.tar.gz'
    archive.write_bytes(native_format.archive_bytes(members, manifest))
    observed = native_format.inspect(archive)
    if observed['manifest'] != manifest:
        raise ValueError('Q native layer changed after sealing')
    receipt = {'schema': 1, 'kind': 'q-native-compiled-layer',
               'archive': str(archive), 'archiveSHA256': observed['archiveSHA256'],
               'manifest': manifest, 'sourceBeforeSHA256': native_layers.digest(output / 'source-before.json'),
               'sourceAfterSHA256': native_layers.digest(output / 'source-after.json'),
               'sourceBuildLogSHA256': native_layers.digest(raw_build_log),
               'sourceBuildEventsSHA256': native_layers.digest(events),
               'buildTargets': build_target if isinstance(build_target, list) else [build_target],
               'buildAspect': aspect_label, 'buildFlags': build_flags,
               'sourceBuild': build_proof, 'sourceSnapshot': source_proof,
               'configuredOutputLogSHA256': native_layers.digest(raw_query_log),
               'loadedLowerBUILD': loaded,
               'developmentProof': nonpublishable}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    return receipt


def _qualification_document(events: Path, source: str, group: str) -> dict:
    reports = events.with_suffix('.tests')
    index = json.loads((reports / 'index.json').read_text())
    names = ['index.json', *(name for row in index for name in row['files'])]
    if len(names) != len(set(names)):
        raise ValueError('qualification reports have duplicate paths')
    for name in names:
        native_evidence._relative(name)
    return {'schema': 1, 'source': source, 'group': group, 'invocations': [{
        'events': str(events), 'eventsSHA256': native_layers.digest(events),
        'reports': {name: native_layers.digest(reports / name) for name in names}}]}


def qualify(group: str, output: Path, *, root: Path = ROOT) -> dict:
    """Run the maintained finite source tests and retain their actual evidence."""
    if group not in GROUPS or not output.is_absolute() or output.exists():
        raise ValueError('qualification requires one group and a fresh absolute output')
    before = _source_state(root)
    if before['dirty']:
        raise ValueError('native qualification requires a clean Q checkout')
    output.mkdir(parents=True, mode=0o700)
    _, log = _run_bazel(root, 'test', [], sorted(native_evidence.GROUP_TEST_TARGETS[group]),
                        output / 'tests.log')
    events = log.with_suffix('.events.json')
    document = _qualification_document(events, before['commit'], group)
    original = output / 'original-qualification.json'
    original.write_text(json.dumps(document, indent=2, sort_keys=True) + '\n')
    inputs = {**before['recipe'], 'Package.resolved': native_layers.digest(root / 'Package.resolved')}
    native_evidence.verify_qualification(original, before['commit'], group,
                                         source_root=root, expected_inputs=inputs)
    local = output / 'qualification.events.json'
    shutil.copy2(events, local)
    for suffix in ('.source.txt', '.diff', '.inputs.sha256'):
        shutil.copy2(events.with_name(events.name.removesuffix('.events.json') + suffix),
                     local.with_name(local.name.removesuffix('.events.json') + suffix))
    reports = local.with_suffix('.tests')
    reports.mkdir()
    for name in document['invocations'][0]['reports']:
        target = reports / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(events.with_suffix('.tests') / name, target)
    shutil.copy2(log, output / 'tests.raw.log')
    after = _source_state(root)
    if before != after:
        raise ValueError('Q source, recipe, pins or toolchain changed during qualification')
    retained = output / 'qualification.json'
    retained.write_text(json.dumps(_qualification_document(local, before['commit'], group),
                                    indent=2, sort_keys=True) + '\n')
    verified = native_evidence.verify_qualification(retained, before['commit'], group,
                                                   source_root=root, expected_inputs=inputs)
    (output / 'qualification-proof.json').write_text(json.dumps(verified, indent=2, sort_keys=True) + '\n')
    return verified


# Actual Bazel BEP includes a client environment dump in these command fields.
# Export removes only those entries. All private originals remain unchanged.
ENV_POLICY = 'remove-client_env-from-structured-and-unstructured-command-lines-v1'
CREDENTIAL = re.compile(
    r'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
    r'|-----BEGIN [A-Z ]*PRIVATE KEY-----'
    r'|(?i:authorization\s*:\s*bearer\s+[^\s"<>]{12,})'
    r'|(?i:(?:token|password|secret|api_key)\s*=\s*[^\s"<>]{12,})')


def _public_bytes(path: Path, *, events: bool = False) -> tuple[bytes, str | None]:
    raw = path.read_bytes()
    policy = None
    if events:
        output = []
        for line in raw.splitlines(keepends=True):
            row = json.loads(line)
            changed = False
            for section in row.get('structuredCommandLine', {}).get('sections', []):
                options = section.get('optionList', {}).get('option')
                if options is not None:
                    kept = [option for option in options if option.get('optionName') != 'client_env']
                    if kept != options:
                        section['optionList']['option'] = kept
                        changed = True
            command = row.get('unstructuredCommandLine', {})
            arguments = command.get('args')
            if arguments is not None:
                kept, skip = [], False
                for argument in arguments:
                    if skip:
                        skip = False
                    elif argument == '--client_env':
                        skip = True
                    elif not argument.startswith('--client_env='):
                        kept.append(argument)
                if skip:
                    raise ValueError('malformed client environment argument')
                if kept != arguments:
                    command['args'] = kept
                    changed = True
            if changed:
                policy = ENV_POLICY
                line = (json.dumps(row, sort_keys=True) + '\n').encode()
            output.append(line)
        raw = b''.join(output)
    if CREDENTIAL.search(raw.decode('utf-8')):
        raise ValueError('credential-like material prevents public evidence export')
    return raw, policy


def _proof_bundle(receipt_path: Path, qualification_path: Path, receipt: dict,
                  qualified: dict, build_proof: dict, output: Path) -> tuple[Path, dict]:
    group = receipt['manifest']['group']
    members, records, locations = {}, {}, {}

    def add(name: str, path: Path, events: bool = False) -> str:
        member = group + '/' + name
        if member in members:
            raise ValueError('duplicate public proof member')
        raw, policy = _public_bytes(path, events=events)
        members[member] = raw
        records[member] = {'sha256': hashlib.sha256(raw).hexdigest(), 'size': len(raw),
                           'originalSHA256': native_layers.digest(path), 'normalization': policy}
        locations[member] = str(path)
        return member

    producer = receipt_path.parent
    event_member = add('producer/source-build.events.json', producer / 'source-build.events.json', True)
    for name in ('source-build.raw.log', 'configured-outputs.raw.log', 'source-build.source.txt',
                 'source-build.diff', 'source-build.inputs.sha256', 'source-before.json', 'source-after.json'):
        add('producer/' + name, producer / name)
    add('producer/receipt.json', receipt_path)
    add('qualification/document.json', qualification_path)
    document = json.loads(qualification_path.read_text())
    invocations = []
    for number, row in enumerate(document['invocations']):
        events = Path(row['events'])
        prefix = 'qualification/' + str(number) + '/'
        invocation = {'events': add(prefix + 'tests.events.json', events, True), 'reports': {}}
        for suffix in ('.source.txt', '.diff', '.inputs.sha256'):
            add(prefix + 'tests' + suffix,
                events.with_name(events.name.removesuffix('.events.json') + suffix))
        for name in row['reports']:
            invocation['reports'][name] = add(prefix + 'tests.events.tests/' + name,
                                                events.with_suffix('.tests') / name)
        invocations.append(invocation)
    manifest = {'schema': 1, 'group': group, 'profile': 'native', 'kind': 'q-native-public-proof',
                'source': receipt['manifest']['producerCommit'], 'normalizationPolicy': ENV_POLICY,
                'files': {name: record['sha256'] for name, record in records.items()},
                'records': records, 'originalLocations': locations,
                'producer': {'events': event_member, 'targets': receipt['buildTargets'],
                             'aspect': receipt['buildAspect'], 'options': receipt['buildFlags'],
                             'originalBuild': build_proof,
                             'exportedOptionsSHA256': hashlib.sha256(json.dumps(
                                 native_evidence._command(
                                     [json.loads(line) for line in members[event_member].splitlines()],
                                     'build')[2], sort_keys=True).encode()).hexdigest()},
                'qualification': qualified, 'invocations': invocations}
    bundle = output / (group + '-native-proof.tar.gz')
    bundle.write_bytes(native_format.archive_bytes(members, manifest))
    binding = {'schema': 1, 'asset': bundle.name, 'sha256': native_layers.digest(bundle),
               'manifestSHA256': hashlib.sha256((json.dumps(manifest, sort_keys=True,
                                                           separators=(',', ':')) + '\n').encode()).hexdigest(),
               'files': records}
    return bundle, binding


def verify_proof_bundle(path: Path, sidecar: dict) -> dict:
    """Replay published command, output and XML evidence without source builds."""
    binding = sidecar['proofBundle']
    observed = native_format.inspect(path, binding['sha256'])
    manifest = observed['manifest']
    manifest_sha = hashlib.sha256((json.dumps(manifest, sort_keys=True,
                                             separators=(',', ':')) + '\n').encode()).hexdigest()
    if (binding.get('schema') != 1 or binding.get('asset') != path.name
            or manifest.get('kind') != 'q-native-public-proof' or manifest.get('source') != sidecar['source']
            or manifest.get('group') != sidecar['group'] or manifest.get('normalizationPolicy') != ENV_POLICY
            or manifest_sha != binding.get('manifestSHA256')
            or manifest.get('records') != binding.get('files')
            or set(manifest['records']) != set(manifest['files'])
            or manifest.get('qualification') != sidecar['qualification']
            or manifest['producer']['originalBuild'] != sidecar['producerBuild']):
        raise ValueError('portable evidence bundle differs from its qualified sidecar')
    with tempfile.TemporaryDirectory(prefix='native-proof-replay-') as temporary:
        root = Path(temporary)
        with tarfile.open(path, 'r:gz') as archive:
            for name, record in manifest['records'].items():
                raw = archive.extractfile(name).read()
                if (len(raw) != record.get('size') or hashlib.sha256(raw).hexdigest() != record.get('sha256')
                        or not native_evidence.SHA.fullmatch(record.get('originalSHA256', ''))
                        or record.get('normalization') not in (None, ENV_POLICY)
                        or (record.get('normalization') is None and record['originalSHA256'] != record['sha256'])):
                    raise ValueError('portable evidence member integrity changed')
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
        producer = manifest['producer']
        events = root / producer['events']
        normalized = native_evidence.verify_build_record(events, producer['targets'], producer['aspect'],
                                                         expected_options=producer['options'])
        original = sidecar['producerBuild']
        if ({key: value for key, value in normalized.items() if key not in ('eventsSHA256', 'optionsSHA256')} !=
                {key: value for key, value in original.items() if key not in ('eventsSHA256', 'optionsSHA256')}
                or manifest['records'][producer['events']]['originalSHA256'] != original['eventsSHA256']
                or normalized['optionsSHA256'] != producer['exportedOptionsSHA256']
                or (manifest['records'][producer['events']]['normalization'] is None
                    and (normalized['optionsSHA256'] != original['optionsSHA256']
                         or normalized['eventsSHA256'] != original['eventsSHA256']))):
            raise ValueError('portable producer command or outputs changed')
        group = manifest['group']
        original_receipt = json.loads((root / group / 'producer/receipt.json').read_text())
        if (original_receipt['archiveSHA256'] != sidecar['archiveSHA256']
                or original_receipt['sourceSnapshot'] != sidecar['producerSourceSnapshot']
                or hashlib.sha256((json.dumps(original_receipt['manifest'], sort_keys=True,
                                               separators=(',', ':')) + '\n').encode()).hexdigest() != sidecar['manifestSHA256']):
            raise ValueError('portable original producer receipt changed')
        expected_raw = {
            'producer/source-before.json': original_receipt['sourceBeforeSHA256'],
            'producer/source-after.json': original_receipt['sourceAfterSHA256'],
            'producer/source-build.raw.log': original_receipt['sourceBuildLogSHA256'],
            'producer/configured-outputs.raw.log': original_receipt['configuredOutputLogSHA256'],
            'qualification/document.json': sidecar['qualificationSHA256'],
        }
        for suffix, field in (('.source.txt', 'sourceSHA256'), ('.diff', 'diffSHA256'),
                              ('.inputs.sha256', 'inputsSHA256')):
            expected_raw['producer/source-build' + suffix] = sidecar['producerSourceSnapshot'][field]
        for name, expected in expected_raw.items():
            if manifest['records'][group + '/' + name]['sha256'] != expected:
                raise ValueError('portable raw producer evidence changed')
        original_qualification = json.loads((root / group / 'qualification/document.json').read_text())
        if (original_qualification.get('source') != sidecar['source']
                or original_qualification.get('group') != sidecar['group']):
            raise ValueError('portable qualification source or group changed')
        seen = set()
        if len(original_qualification['invocations']) != len(manifest['invocations']):
            raise ValueError('portable qualification invocation inventory changed')
        for number, (invocation, verified) in enumerate(zip(manifest['invocations'], sidecar['qualification']['invocations'], strict=True)):
            original_invocation = original_qualification['invocations'][number]
            if (original_invocation['eventsSHA256'] != verified['eventsSHA256']
                    or set(original_invocation['reports']) != set(invocation['reports'])):
                raise ValueError('portable original qualification inventory changed')
            for name, member in invocation['reports'].items():
                if manifest['records'][member]['sha256'] != original_invocation['reports'][name]:
                    raise ValueError('portable original test report changed')
            for suffix, field in (('.source.txt', 'sourceSHA256'), ('.diff', 'diffSHA256'),
                                  ('.inputs.sha256', 'inputsSHA256')):
                member = group + '/qualification/' + str(number) + '/tests' + suffix
                if manifest['records'][member]['sha256'] != verified['source'][field]:
                    raise ValueError('portable source-test snapshot changed')
            events = root / invocation['events']
            rows = native_evidence._events(events)
            started, targets, options = native_evidence._command(rows, 'test')
            values = native_evidence._values
            if (values(options, 'compilation_mode') != ['dbg'] or values(options, 'override_repository')
                    or any(values(options, key) for key in ('test_filter', 'test_arg', 'test_tag_filters',
                                                           'test_lang_filters', 'test_size_filters',
                                                           'test_timeout_filters'))
                    or values(options, 'runs_per_test') not in ([], ['1'])
                    or any(value.startswith('prebuilt') for value in values(options, 'config'))):
                raise ValueError('portable qualification is not original unfiltered source mode')
            selected = set()
            for target in map(native_evidence._label, targets):
                if target in native_evidence.ALL_TEST_TARGETS:
                    selected.add(target)
                elif target in native_evidence.SUITE_TARGETS:
                    selected.update(native_evidence.SUITE_TARGETS[target])
                else:
                    raise ValueError('portable qualification selected an unreviewed target')
            summaries = [row for row in rows if 'testSummary' in row]
            labels = [native_evidence._label(row['id']['testSummary']['label']) for row in summaries]
            configurations = {native_evidence._label(row['id']['testResult']['label']):
                              row['id']['testResult'].get('configuration') for row in rows if 'testResult' in row}
            if (len(labels) != len(set(labels)) or set(labels) != selected or seen & selected
                    or any(row['testSummary'].get('overallStatus') != 'PASSED' for row in summaries)
                    or any(row['id']['testSummary'].get('configuration') !=
                           configurations.get(native_evidence._label(row['id']['testSummary']['label']))
                           for row in summaries)):
                raise ValueError('portable qualification summaries failed or changed configuration')
            seen.update(selected)
            reports = events.with_suffix('.tests')
            expected = {name: manifest['records'][member]['sha256']
                        for name, member in invocation['reports'].items()}
            actual = native_evidence._test_reports(rows, reports, expected)
            if (selected != set(verified['targets']) or actual != verified['reports']
                    or started['uuid'] != verified['invocation']
                    or manifest['records'][invocation['events']]['originalSHA256'] != verified['eventsSHA256']):
                raise ValueError('portable source-test evidence changed')
        if not native_evidence.GROUP_TEST_TARGETS[sidecar['group']].issubset(seen):
            raise ValueError('portable qualification omitted required group tests')
    return {'schema': 1, 'passed': True, 'sha256': observed['archiveSHA256'],
            'manifestSHA256': manifest_sha, 'members': len(manifest['records'])}


def plan(receipt_path: Path, qualification_path: Path, output: Path) -> dict:
    if not output.is_absolute() or output.exists():
        raise ValueError('native publication plan requires a fresh absolute output')
    receipt = json.loads(receipt_path.read_text())
    archive = Path(receipt['archive'])
    observed = native_format.inspect(archive, receipt['archiveSHA256'])
    manifest = observed['manifest']
    before_path = receipt_path.parent / 'source-before.json'
    after_path = receipt_path.parent / 'source-after.json'
    before = json.loads(before_path.read_text())
    after = json.loads(after_path.read_text())
    if (before != after or before != _source_state(ROOT) or before['dirty']
            or native_layers.digest(before_path) != receipt.get('sourceBeforeSHA256')
            or native_layers.digest(after_path) != receipt.get('sourceAfterSHA256')
            or before['commit'] != manifest.get('producerCommit')
            or before['recipe'] != manifest.get('recipeSHA256')
            or before['toolchain'] != manifest.get('toolchain')
            or before['pins'] != native_layers.pin_records(ROOT)):
        raise ValueError('native producer source, recipe, pins or toolchain changed')
    build_log = receipt_path.parent / 'source-build.raw.log'
    events = receipt_path.parent / 'source-build.events.json'
    query_log = receipt_path.parent / 'configured-outputs.raw.log'
    if (native_layers.digest(build_log) != receipt.get('sourceBuildLogSHA256')
            or native_layers.digest(events) != receipt.get('sourceBuildEventsSHA256')
            or native_layers.digest(query_log) != receipt.get('configuredOutputLogSHA256')):
        raise ValueError('native producer build or configured-output evidence changed')
    qualified = native_evidence.verify_qualification(
        qualification_path, manifest['producerCommit'], manifest['group'], source_root=ROOT,
        expected_inputs={**before['recipe'], 'Package.resolved': native_layers.digest(ROOT / 'Package.resolved')})
    source_snapshot = native_evidence.verify_source_snapshot(
        events, before['commit'], ROOT,
        {**before['recipe'], 'Package.resolved': native_layers.digest(ROOT / 'Package.resolved')})
    if (receipt.get('kind') != 'q-native-compiled-layer'
            or receipt.get('developmentProof') is not False
            or manifest.get('developmentProof') is not False
            or receipt['manifest'] != manifest
            or receipt.get('sourceSnapshot') != source_snapshot
            or qualified.get('passed') is not True):
        raise ValueError('native group has no exact passed qualification')
    group = manifest['group']
    if (group not in GROUPS or manifest.get('sourcePins') !=
            ({'swift-argument-parser': before['pins']['swift-argument-parser']}
             if group == 'argument-parser' else
             native_layers.group_pins(group, before['pins']))):
        raise ValueError('native group source pins changed after production')
    lower_groups = () if group == 'foundation' else ('foundation',)
    current_lower = ({} if group == 'argument-parser' else
                     native_layers.import_layers(ROOT, groups=lower_groups)['layers'])
    if manifest.get('lower') != {
            name: native_layers.lower_identity(current_lower[name])
            for name in native_layers.LOWER[group]}:
        raise ValueError('native group lower published archive changed after production')
    build_proof = native_evidence.verify_build_record(
        events, receipt['buildTargets'], receipt['buildAspect'],
        expected_options=receipt['buildFlags'])
    recorded_build = receipt.get('sourceBuild')
    if (not isinstance(recorded_build, dict)
            or {key: value for key, value in build_proof.items() if key != 'files'} !=
               {key: value for key, value in recorded_build.items() if key != 'files'}
            or any(build_proof['files'].get(name) != record
                   for name, record in recorded_build.get('files', {}).items())):
        raise ValueError('native producer successful build proof changed')
    outputs = manifest.get('payloadOutputs')
    if (not isinstance(outputs, dict) or not outputs or
            set(outputs) != {name for name in manifest['files'] if '/binary/' in name}):
        raise ValueError('native archive is not bound to configured compiler outputs')
    with tarfile.open(archive, 'r:gz') as sealed:
        member_sizes = {item.name: item.size for item in sealed if item.name in outputs}
    for member, configured in outputs.items():
        record = recorded_build['files'].get(configured)
        if (record is None or manifest['files'][member] != record['sha256']
                or member_sizes.get(member) != record['size']):
            raise ValueError('native archive binary differs from successful build BEP')
    tag = f'layer-{manifest["group"]}-native-{manifest["producerCommit"][:12]}-{observed["archiveSHA256"][:20]}'
    target = (manifest['producerCommit'] if group in ('argument-parser', 'foundation') else
              manifest['sourcePins'][native_layers.GROUP_PIN[group]]['state']['revision'])
    sidecar = {'schema': 1, 'group': group, 'passed': True,
               'developmentProof': False, 'source': manifest['producerCommit'],
               'archiveSHA256': observed['archiveSHA256'],
               'sourcePins': manifest['sourcePins'],
               'recipeSHA256': manifest['recipeSHA256'],
               'toolchain': manifest['toolchain'],
               'lower': manifest['lower'],
               'manifestSHA256': hashlib.sha256((json.dumps(manifest, sort_keys=True,
                                       separators=(',', ':')) + '\n').encode()).hexdigest(),
               'qualificationSHA256': qualified['qualificationSHA256'],
               'sourceInputsSHA256': receipt['sourceBeforeSHA256'],
               'producerEventsSHA256': receipt['sourceBuildEventsSHA256'],
               'producerSourceSnapshot': source_snapshot,
               'producerBuild': build_proof,
               'qualification': qualified,
               'tests': {name: report['reportSHA256']['test.xml']
                         for invocation in qualified['invocations']
                         for report in invocation['reports']
                         for name in [report['label']]}}
    output.mkdir(parents=True, mode=0o700)
    sealed_copy = output / archive.name
    shutil.copy2(archive, sealed_copy)
    if native_layers.digest(sealed_copy) != observed['archiveSHA256']:
        raise ValueError('native archive changed while staging publication')
    archive = sealed_copy
    proof, sidecar['proofBundle'] = _proof_bundle(receipt_path, qualification_path, receipt,
                                                 qualified, build_proof, output)
    verify_proof_bundle(proof, sidecar)
    evidence = output / f'{group}-native-evidence.json'
    evidence.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + '\n')
    result = {}
    for name, value in [('archive', archive), ('evidence', evidence), ('proof', proof)]:
        asset = value.name
        lock = {'schema': 1, 'repository': native_layers.GROUP_OWNER[group],
                'tag': tag, 'targetCommit': target, 'asset': asset,
                'sha256': native_layers.digest(value)}
        path = output / f'{group}.{name}.lock.json'
        path.write_text(json.dumps(lock, indent=2, sort_keys=True) + '\n')
        result[name] = lock
    (output / 'plan.json').write_text(json.dumps({'schema': 1, 'group': group,
        'source': manifest['producerCommit'], 'qualified': True, 'published': False,
        'assets': result}, indent=2, sort_keys=True) + '\n')
    return result


def publish(receipt_path: Path, qualification_path: Path, output: Path) -> dict:
    """Revalidate original evidence, publish once, then verify all released bytes."""
    locks = plan(receipt_path, qualification_path, output)
    receipt = json.loads(receipt_path.read_text())
    group = receipt['manifest']['group']
    paths = {'archive': output / locks['archive']['asset'],
             'evidence': output / locks['evidence']['asset'], 'proof': output / locks['proof']['asset']}
    # The transport independently hashes and verifies draft downloads before
    # publishing, and rejects an existing release instead of overwriting it.
    first = locks['archive']
    before = json.loads((receipt_path.parent / 'source-before.json').read_text())
    if _source_state(ROOT) != before or any(native_layers.digest(path) != locks[name]['sha256']
                                            for name, path in paths.items()):
        raise ValueError('native source or staged bytes changed before publication')
    proof_manifest = native_format.inspect(paths['proof'])['manifest']
    if any(native_layers.digest(Path(proof_manifest['originalLocations'][name])) != record['originalSHA256']
           for name, record in proof_manifest['records'].items()):
        raise ValueError('original native evidence changed immediately before publication')
    publication = publish_assets(first['repository'], first['tag'], first['targetCommit'],
        'Qualified native ' + group, 'Compiled native dependency with source-test and build evidence.',
        tuple(paths.values()))
    (output / 'publication.json').write_text(json.dumps(publication, indent=2, sort_keys=True) + '\n')
    if (publication.get('repository') != first['repository'] or publication.get('tag') != first['tag']
            or publication.get('targetCommit') != first['targetCommit']
            or set(publication.get('assets', {})) != {path.name for path in paths.values()}):
        raise ValueError('published native release identity differs from admitted plan')
    downloads = {}
    for name, lock in locks.items():
        downloaded = fetch(output / f'{group}.{name}.lock.json', output / ('download-' + name))
        asset = publication['assets'][lock['asset']]
        if (downloaded.get('releaseId') != publication.get('releaseId')
                or downloaded.get('assetId') != asset.get('assetId')
                or downloaded.get('sha256') != lock['sha256'] or asset.get('sha256') != lock['sha256']
                or native_layers.digest(Path(downloaded['asset'])) != lock['sha256']):
            raise ValueError('downloaded native release identity or bytes changed')
        downloads[name] = downloaded
    if len({row['assetId'] for row in downloads.values()}) != len(downloads):
        raise ValueError('native published assets do not have distinct identities')
    native_format.inspect(Path(downloads['archive']['asset']), locks['archive']['sha256'])
    sidecar = json.loads(Path(downloads['evidence']['asset']).read_text())
    proof = verify_proof_bundle(Path(downloads['proof']['asset']), sidecar)
    result = {'schema': 1, 'passed': True, 'source': receipt['manifest']['producerCommit'],
              'releaseId': publication['releaseId'], 'downloads': downloads, 'proof': proof}
    (output / 'download-verification.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('produce', 'qualify', 'plan', 'publish'))
    parser.add_argument('--group', choices=GROUPS)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--development-proof', action='store_true')
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--qualification', type=Path)
    arguments = parser.parse_args()
    if arguments.action in ('produce', 'qualify'):
        if not arguments.group:
            parser.error(arguments.action + ' requires --group')
        if arguments.action == 'produce':
            produce(arguments.group, arguments.output, development_proof=arguments.development_proof)
        else:
            if arguments.development_proof:
                parser.error('qualify does not permit development proof')
            qualify(arguments.group, arguments.output)
    else:
        if not arguments.receipt or not arguments.qualification:
            parser.error(arguments.action + ' requires --receipt and --qualification')
        if arguments.development_proof:
            parser.error('publication does not permit development proof')
        (plan if arguments.action == 'plan' else publish)(
            arguments.receipt, arguments.qualification, arguments.output)


if __name__ == '__main__':
    main()
