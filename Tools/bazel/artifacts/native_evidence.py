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

"""Validate retained native build and source-test evidence without running tools."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET

SHA = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
# Exact maintained non-Container test inventory in Tools/bazel/layers.bzl.
# Changing the inventory requires reviewing this publication admission too.
TEST_LAYERS = {'algorithms': ('swift-algorithms', ('SwiftAlgorithmsTests',)),
 'argument-parser': ('swift-argument-parser',
                     ('ArgumentParserUnitTests', 'ArgumentParserToolInfoTests')),
 'asn1': ('swift-asn1', ('SwiftASN1Tests',)),
 'async-algorithms': ('swift-async-algorithms', ('AsyncAlgorithmsTests',)),
 'async-http-client': ('async-http-client', ('AsyncHTTPClientTests',)),
 'atomics': ('swift-atomics', ('AtomicsTests',)),
 'aws-cloudwatch': ('aws-sdk-swift',
                    ('AWSClientRuntimeTests',
                     'AWSSDKEventStreamsAuthTests',
                     'AWSSDKHTTPAuthTests',
                     'AWSSDKIdentityTests')),
 'aws-crt': ('aws-crt-swift', ('AwsCommonRuntimeKitOfflineTests',)),
 'certificates': ('swift-certificates', ('X509Tests',)),
 'collections': ('swift-collections',
                 ('DequeTests', 'OrderedCollectionsTests', 'CollectionsModuleTests')),
 'configuration': ('swift-configuration', ('ConfigurationTests',)),
 'configuration-toml': ('swift-configuration-toml', ('ConfigurationTOMLTests',)),
 'containerization': ('containerization', ('ContainerizationUnitTests',)),
 'containerization-archive': ('containerization', ('ContainerizationArchiveTests',)),
 'containerization-cli': ('containerization', ('cctlTests',)),
 'containerization-ext4': ('containerization', ('ContainerizationEXT4Tests',)),
 'containerization-guest-core': ('containerization', ('VminitdCoreTests',)),
 'containerization-hypervisor': ('containerization', ('CloudHypervisorTests',)),
 'containerization-netlink': ('containerization', ('ContainerizationNetlinkTests',)),
 'containerization-oci': ('containerization', ('ContainerizationOCITests',)),
 'containerization-os': ('containerization',
                         ('ContainerizationOSTests', 'ContainerizationExtrasTests')),
 'crypto': ('swift-crypto', ('CryptoTests', '_CryptoExtrasTests')),
 'domain-names': ('tldextractswift', ('TLDExtractSwiftTests',)),
 'engine-core': ('container-engine-api',
                 ('ContainerEngineRuntimeSPITests',
                  'ContainerEngineRouterTests',
                  'ContainerEngineLoggingTests')),
 'engine-gateway': ('container-engine-api', ('ContainerEngineGatewayTests',)),
 'engine-service': ('container-engine-api', ('ContainerEngineServiceTests',)),
 'engine-session': ('container-engine-api', ('ContainerEngineProviderSessionTests',)),
 'engine-transport': ('container-engine-api',
                      ('ContainerUnixHTTPServerTests', 'ContainerUnixHTTPClientTests')),
 'engine-wire': ('container-engine-api', ('ContainerEngineWireTests',)),
 'grpc-core': ('grpc-swift-2', ('GRPCCoreTests', 'GRPCInProcessTransportTests')),
 'grpc-protobuf': ('grpc-swift-protobuf', ('GRPCProtobufTests',)),
 'grpc-transport': ('grpc-swift-nio-transport',
                    ('GRPCNIOTransportCoreTests', 'GRPCNIOTransportHTTP2Tests')),
 'http-types': ('swift-http-types', ('HTTPTypesTests',)),
 'logging': ('swift-log', ('LoggingTests',)),
 'metrics': ('swift-metrics', ('MetricsTests',)),
 'nio': ('swift-nio', ('NIOCoreTests', 'NIOEmbeddedTests', 'NIOHTTP1Tests')),
 'nio-extras': ('swift-nio-extras', ('NIOExtrasTests', 'NIOHTTPCompressionTests', 'NIOSOCKSTests')),
 'nio-http2': ('swift-nio-http2', ('NIOHTTP2Tests', 'NIOHPACKTests')),
 'nio-ssl': ('swift-nio-ssl', ('NIOSSLTests',)),
 'nio-transport-services': ('swift-nio-transport-services', ('NIOTransportServicesTests',)),
 'numerics': ('swift-numerics', ('RealTests', 'ComplexTests')),
 'protobuf': ('swift-protobuf', ('SwiftProtobufTests',)),
 'punycode': ('punycodeswift', ('PunycodeSwiftTests',)),
 'service-context': ('swift-service-context', ('ServiceContextTests',)),
 'service-lifecycle': ('swift-service-lifecycle', ('ServiceLifecycleTests',)),
 'structured-headers': ('swift-http-structured-headers', ('StructuredFieldValuesTests',)),
 'system': ('swift-system', ('SystemTests',)),
 'toml': ('swift-toml', ('TOMLTests',)),
 'tracing': ('swift-distributed-tracing', ('InstrumentationTests', 'TracingTests')),
 'yaml': ('yams', ('YamsTests',))}


def _label(value: str) -> str:
    if value.startswith('@@+dependencies+'):
        return '@' + value.removeprefix('@@+dependencies+')
    return value.removeprefix('@@') if value.startswith('@@//') else value


def _test_label(package: str, name: str) -> str:
    return '@swiftpkg_' + package.replace('-', '_') + '//:' + name + '.rspm'


SUITE_TARGETS = {
    '//:' + layer + '-tests': frozenset(_test_label(package, name) for name in tests)
    for layer, (package, tests) in TEST_LAYERS.items()
}
ALL_TEST_TARGETS = frozenset().union(*SUITE_TARGETS.values())
SUITE_TARGETS['//:dependency-tests'] = ALL_TEST_TARGETS
GROUP_TEST_TARGETS = {
    group: frozenset(
        _test_label(package, name)
        for package, tests in TEST_LAYERS.values()
        if (package == {'argument-parser': 'swift-argument-parser',
                        'containerization': 'containerization',
                        'engine-api': 'container-engine-api'}.get(group)
            or group == 'foundation' and package not in
            {'swift-argument-parser', 'containerization', 'container-engine-api'})
        for name in tests)
    for group in ('argument-parser', 'foundation', 'containerization', 'engine-api')
}


def _sha(path: Path) -> str:
    if not path.is_file():
        raise ValueError('evidence is not a regular file')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _one(values: list, description: str):
    if len(values) != 1:
        raise ValueError('expected exactly one ' + description)
    return values[0]


def _events(path: Path) -> list[dict]:
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    if not rows or any(not isinstance(row, dict) or 'aborted' in row for row in rows):
        raise ValueError('missing or aborted build events')
    return rows


def _command(events: list[dict], action: str) -> tuple[dict, list[str], list[dict]]:
    started = _one([e['started'] for e in events if 'started' in e], 'started event')
    finished = _one([e['finished'] for e in events if 'finished' in e], 'finished event')
    if (started.get('command') != action or not isinstance(started.get('uuid'), str)
            or not started['uuid'] or finished.get('overallSuccess') is not True
            or finished.get('exitCode', {}).get('name') != 'SUCCESS'
            or finished.get('exitCode', {}).get('code', 0) != 0):
        raise ValueError('invocation did not complete the required command successfully')
    canonical = _one([e['structuredCommandLine'] for e in events
                      if e.get('structuredCommandLine', {}).get('commandLineLabel') == 'canonical'],
                     'canonical command')
    sections = canonical.get('sections', [])
    command = _one([s['chunkList']['chunk'] for s in sections
                    if s.get('sectionLabel') == 'command'], 'command section')
    targets = _one([s['chunkList']['chunk'] for s in sections
                    if s.get('sectionLabel') == 'residual'], 'target section')
    options = [o for s in sections for o in s.get('optionList', {}).get('option', [])]
    if command != [action] or not targets or len(targets) != len(set(map(_label, targets))):
        raise ValueError('missing, duplicate or inconsistent command targets')
    return started, targets, options


def _values(options: list[dict], name: str) -> list[str]:
    return [o['optionValue'] for o in options if o.get('optionName') == name]


def _relative(value: str) -> str:
    if (not isinstance(value, str) or not value or value.startswith('/')
            or any(part in ('', '.', '..') for part in value.split('/'))):
        raise ValueError('noncanonical evidence path')
    return value


def _file_record(file: dict) -> tuple[str, Path, dict]:
    relative = _relative('/'.join([*file.get('pathPrefix', []), file['name']]))
    if not relative.startswith('bazel-out/'):
        raise ValueError('selected output is not a configured Bazel output')
    uri = urlparse(file.get('uri', ''))
    if uri.scheme != 'file' or uri.netloc or uri.query or uri.fragment:
        raise ValueError('selected output has no local file URI')
    path = Path(unquote(uri.path))
    if not path.is_absolute() or not path.as_posix().endswith('/' + relative):
        raise ValueError('output URI differs from its configured relative path')
    digest, length = file.get('digest'), file.get('length')
    if (not isinstance(digest, str) or not SHA.fullmatch(digest)
            or not isinstance(length, str) or not length.isascii() or not length.isdigit()):
        raise ValueError('selected output lacks a digest and size')
    return relative, path, {'sha256': digest, 'size': int(length)}


def _build_record(events_path: Path, requested_targets: list[str], aspect: str | None,
                  expected_options: list[str] | None) -> tuple[dict, dict[str, Path]]:
    """Validate one build's selected output metadata without reading payload files."""
    events_path = Path(events_path)
    events = _events(events_path)
    started, targets, options = _command(events, 'build')
    expected = list(map(_label, requested_targets))
    if not expected or len(expected) != len(set(expected)) or list(map(_label, targets)) != expected:
        raise ValueError('build requested targets differ from the producer contract')
    if _values(options, 'compilation_mode') != ['opt'] or 'release' not in _values(options, 'config'):
        raise ValueError('native production build is not optimized release configuration')
    supplied = expected_options or []
    for option in supplied:
        name, separator, value = option.removeprefix('--').partition('=')
        if not option.startswith('--') or not separator or value not in _values(options, name):
            raise ValueError('build option differs from producer contract')
    for key in ('override_repository', 'aspects', 'output_groups'):
        wanted = [x.split('=', 1)[1] for x in supplied if x.startswith('--' + key + '=')]
        if expected_options is not None and sorted(_values(options, key)) != sorted(wanted):
            raise ValueError('build dependency overrides or aspect selection changed')
    if aspect:
        selection = [x.split('=', 1)[1] for x in supplied if x.startswith('--output_groups=')]
        if (expected_options is None or selection not in (['layer_compiled'], ['+layer_compiled'])
                or _values(options, 'aspects') != [aspect]
                or _values(options, 'output_groups') != selection):
            raise ValueError('build did not request the trusted exact compiled-output selection')
    elif _values(options, 'aspects') or _values(options, 'output_groups'):
        raise ValueError('unexpected aspect on direct native output build')
    sets = {}
    for event in events:
        if 'namedSetOfFiles' in event:
            identity = event['id']['namedSet']['id']
            if identity in sets:
                raise ValueError('duplicate named output set')
            sets[identity] = event['namedSetOfFiles']
    completed = [e for e in events if 'completed' in e]
    admitted = {}
    visiting = set()
    visited = set()

    def collect(identity: str) -> None:
        if identity in visiting or identity not in sets:
            raise ValueError('missing or cyclic named output set')
        if identity in visited:
            return
        visiting.add(identity)
        local = set()
        for file in sets[identity].get('files', []):
            relative, path, record = _file_record(file)
            if relative in local or (relative in admitted and admitted[relative] != (path, record)):
                raise ValueError('duplicate or conflicting configured output')
            local.add(relative)
            admitted[relative] = path, record
        for child in sets[identity].get('fileSets', []):
            collect(child['id'])
        visiting.remove(identity)
        visited.add(identity)

    for target in expected:
        ordinary = _one([e for e in completed
                         if _label(e.get('id', {}).get('targetCompleted', {}).get('label', '')) == target
                         and not e['id']['targetCompleted'].get('aspect')], 'successful requested target')
        if (ordinary['completed'].get('success') is not True
                or not ordinary['id']['targetCompleted'].get('configuration', {}).get('id')):
            raise ValueError('requested target failed')
        chosen = ordinary
        if aspect:
            chosen = _one([e for e in completed
                           if _label(e.get('id', {}).get('targetCompleted', {}).get('label', '')) == target
                           and _label(e['id']['targetCompleted'].get('aspect', '')) == aspect],
                          'successful requested aspect')
            if (chosen['completed'].get('success') is not True
                    or chosen['id']['targetCompleted'].get('configuration') !=
                    ordinary['id']['targetCompleted'].get('configuration')):
                raise ValueError('requested aspect failed or changed configuration')
        name = 'layer_compiled' if aspect else 'default'
        group = _one([x for x in chosen['completed'].get('outputGroup', [])
                      if x.get('name') == name], 'required output group')
        if group.get('incomplete') or not group.get('fileSets'):
            raise ValueError('compiled output group is incomplete')
        for entry in group['fileSets']:
            collect(entry['id'])
    if not admitted:
        raise ValueError('native payload has no selected outputs')
    return ({'schema': 1, 'invocation': started['uuid'], 'eventsSHA256': _sha(events_path),
             'targets': expected, 'aspect': aspect, 'configuration': 'opt',
             'optionsSHA256': hashlib.sha256(json.dumps(options, sort_keys=True).encode()).hexdigest(),
             'files': {name: record for name, (_, record) in admitted.items()}},
            {name: path for name, (path, _) in admitted.items()})


def verify_build_record(events_path: Path, requested_targets: list[str], aspect: str | None = None,
                        *, expected_options: list[str]) -> dict:
    """Verify retained BEP metadata after configured output files may have expired.

    This does not verify payload bytes. Publication must compare every archived
    payload member's digest and size to its explicit configured output mapping
    in this result, and bind the retained BEP digest to the sealed build receipt.
    """
    if expected_options is None:
        raise ValueError('retained build metadata requires trusted options')
    return _build_record(events_path, requested_targets, aspect, expected_options)[0]


def verify_build(events_path: Path, requested_targets: list[str], aspect: str | None = None,
                 required_files: dict[str, Path] | None = None, *,
                 expected_options: list[str] | None = None) -> dict:
    """Bind selected payload bytes to successful target/aspect output closures.

    required_files maps configured bazel-out paths to the actual selected files.
    None verifies every admitted closure output; an empty selection is rejected.
    expected_options is the producer's trusted requested option vector. Aspect
    builds require an explicit layer_compiled or +layer_compiled selection.
    """
    result, paths = _build_record(events_path, requested_targets, aspect, expected_options)
    selected = required_files if required_files is not None else paths
    if not selected:
        raise ValueError('native payload has no selected outputs')
    verified = {}
    for name, actual in selected.items():
        _relative(name)
        if name not in paths:
            raise ValueError('selected payload was not an output of the successful build')
        expected_path, record = paths[name], result['files'][name]
        actual = Path(actual)
        if (actual.resolve(strict=True) != expected_path.resolve(strict=True)
                or not actual.is_file() or actual.stat().st_size != record['size']
                or _sha(actual) != record['sha256']):
            raise ValueError('selected payload differs from the build output digest or size')
        verified[name] = record
    return {**result, 'files': verified}


def verify_source_snapshot(events_path: Path, source: str, root: Path,
                     expected_inputs: dict[str, str]) -> dict:
    """Bind a retained invocation snapshot to caller-supplied source/recipe identity."""
    stem = events_path.name.removesuffix('.events.json')
    paths = {name: events_path.with_name(stem + suffix) for name, suffix in
             [('source', '.source.txt'), ('diff', '.diff'), ('inputs', '.inputs.sha256')]}
    text = paths['source'].read_text()
    roots = re.findall(r'^source=(.+)$', text, re.M)
    heads = re.findall(r'^head=(.+)$', text, re.M)
    if (heads != [source] or len(roots) != 1 or Path(roots[0]).resolve() != root.resolve()
            or paths['diff'].read_bytes() or re.search(r'^(?:\?\?|[ MARCDU!]{2}) ', text, re.M)):
        raise ValueError('source-mode tests used a different or dirty source snapshot')
    recorded = {}
    for line in paths['inputs'].read_text().splitlines():
        digest, separator, relative = line.partition('  ')
        _relative(relative)
        if not separator or not SHA.fullmatch(digest) or relative in recorded:
            raise ValueError('malformed or duplicate test source input')
        file = root / relative
        if not file.resolve(strict=True).is_relative_to(root.resolve()) or not file.is_file() or _sha(file) != digest:
            raise ValueError('test source input no longer matches the retained snapshot')
        recorded[relative] = digest
    if not expected_inputs or any(recorded.get(k) != v for k, v in expected_inputs.items()):
        raise ValueError('test source inputs differ from the trusted producer recipe')
    return {name + 'SHA256': _sha(path) for name, path in paths.items()}


def _test_reports(events: list[dict], directory: Path, expected: dict[str, str]) -> list[dict]:
    if not isinstance(expected, dict) or 'index.json' not in expected:
        raise ValueError('missing retained test report digest inventory')
    for name, digest in expected.items():
        _relative(name)
        path = directory / name
        if (not isinstance(digest, str) or not SHA.fullmatch(digest) or path.is_symlink()
                or not path.resolve(strict=True).is_relative_to(directory.resolve())
                or not path.is_file() or _sha(path) != digest):
            raise ValueError('retained test report changed')
    index = json.loads((directory / 'index.json').read_text())
    results = [e for e in events if 'testResult' in e]
    if not isinstance(index, list) or len(index) != len(results) or not results:
        raise ValueError('retained test index differs from event results')
    used = {'index.json'}
    reports = []
    seen = set()
    for result, row in zip(results, index):
        identity = result['id']['testResult']
        label = _label(identity['label'])
        if (label in seen or row.get('id') != result['id'] or row.get('status') != 'PASSED'
                or result['testResult'].get('status') != 'PASSED'
                or any(identity.get(k, 1) != 1 for k in ('attempt', 'run', 'shard'))):
            raise ValueError('failed, duplicate or retried test result')
        seen.add(label)
        files = row.get('files', [])
        if len(files) != 2 or {Path(x).name for x in files} != {'test.xml', 'test.log'}:
            raise ValueError('required raw test XML or log is missing')
        if any(x not in expected or x in used for x in files):
            raise ValueError('unbound or shared retained test report')
        used.update(files)
        outputs = result['testResult'].get('testActionOutput', [])
        if {x.get('name') for x in outputs} != {'test.xml', 'test.log'} or len(outputs) != 2:
            raise ValueError('test event report inventory differs')
        for file in files:
            item = next(x for x in outputs if x['name'] == Path(file).name)
            if item.get('digest') and item['digest'] != expected[file]:
                raise ValueError('test report digest differs from BEP')
        xml = ET.fromstring((directory / next(x for x in files if x.endswith('/test.xml'))).read_bytes())
        cases = list(xml.iter('testcase'))
        skipped = [case for case in cases if case.find('skipped') is not None
                   or case.get('status') in ('notrun', 'disabled', 'skipped')
                   or case.get('result') in ('skipped', 'suppressed')]
        if (not cases or len(skipped) == len(cases) or list(xml.iter('failure')) or list(xml.iter('error'))
                or any(int(node.get(k, '0')) for node in xml.iter() for k in ('failures', 'errors'))):
            raise ValueError('test XML has failure or no executed cases')
        reports.append({'label': label, 'executed': len(cases) - len(skipped), 'skipped': len(skipped),
                        'reportSHA256': {Path(f).name: expected[f] for f in files}})
    if used != set(expected):
        raise ValueError('test digest inventory includes unreferenced reports')
    return reports


def verify_qualification(path: Path, expected_source: str, group: str, *,
                         source_root: Path, expected_inputs: dict[str, str]) -> dict:
    """Read finite source-mode test proofs; digest strings alone are insufficient.

    Input schema: {schema: 1, source, group, invocations: [{events: absolute path,
    eventsSHA256, reports: {relative retained report path: SHA256}}]}.
    source_root and expected_inputs are trusted producer inputs, not JSON claims.
    """
    if group not in GROUP_TEST_TARGETS or not COMMIT.fullmatch(expected_source):
        raise ValueError('unknown native group or producer source')
    path = Path(path)
    document = json.loads(path.read_text())
    if (set(document) != {'schema', 'source', 'group', 'invocations'}
            or type(document['schema']) is not int or document['schema'] != 1
            or document['source'] != expected_source or document['group'] != group
            or not isinstance(document['invocations'], list) or not document['invocations']):
        raise ValueError('native qualification has no exact finite invocation inventory')
    invocations, seen = [], set()
    for row in document['invocations']:
        if set(row) != {'events', 'eventsSHA256', 'reports'}:
            raise ValueError('unknown qualification invocation fields')
        events_path = Path(row['events'])
        if (not events_path.is_absolute() or not events_path.name.endswith('.events.json')
                or not isinstance(row['eventsSHA256'], str) or not SHA.fullmatch(row['eventsSHA256'])
                or _sha(events_path) != row['eventsSHA256']):
            raise ValueError('qualification BEP is missing or changed')
        events = _events(events_path)
        started, targets, options = _command(events, 'test')
        if (_values(options, 'compilation_mode') != ['dbg'] or _values(options, 'override_repository')
                or _values(options, 'test_filter') or _values(options, 'test_arg')
                or _values(options, 'test_tag_filters')
                or _values(options, 'test_lang_filters') or _values(options, 'test_size_filters')
                or _values(options, 'test_timeout_filters') or _values(options, 'runs_per_test') not in ([], ['1'])
                or any(x.startswith('prebuilt') for x in _values(options, 'config'))):
            raise ValueError('qualification is not the original unfiltered source test mode')
        selected = set()
        for target in map(_label, targets):
            if target in ALL_TEST_TARGETS:
                selected.add(target)
            elif target in SUITE_TARGETS:
                selected.update(SUITE_TARGETS[target])
            else:
                raise ValueError('qualification requested an unreviewed test target')
        summaries = [e for e in events if 'testSummary' in e]
        labels = [_label(e['id']['testSummary']['label']) for e in summaries]
        if (len(labels) != len(set(labels)) or set(labels) != selected or seen & selected
                or any(e['testSummary'].get('overallStatus') != 'PASSED' for e in summaries)):
            raise ValueError('missing, failed, duplicate or repeated test target summary')
        snapshots = verify_source_snapshot(events_path, expected_source, Path(source_root), expected_inputs)
        if Path(started.get('workspaceDirectory', '')).resolve() != Path(source_root).resolve():
            raise ValueError('test invocation workspace differs from source snapshot')
        reports = _test_reports(events, events_path.with_suffix('.tests'), row['reports'])
        if {r['label'] for r in reports} != selected:
            raise ValueError('test reports differ from selected targets')
        configurations = {_label(e['id']['testResult']['label']):
                          e['id']['testResult'].get('configuration')
                          for e in events if 'testResult' in e}
        if any(e['id']['testSummary'].get('configuration') !=
               configurations[_label(e['id']['testSummary']['label'])] for e in summaries):
            raise ValueError('test summary and report configurations differ')
        seen.update(selected)
        invocations.append({'invocation': started['uuid'], 'eventsSHA256': row['eventsSHA256'],
                            'source': snapshots, 'targets': sorted(selected), 'reports': reports})
    if not GROUP_TEST_TARGETS[group].issubset(seen):
        raise ValueError('qualification is missing required native group tests')
    return {'schema': 1, 'source': expected_source, 'group': group, 'passed': True,
            'qualificationSHA256': _sha(path), 'requiredTargets': sorted(GROUP_TEST_TARGETS[group]),
            'invocations': invocations}
