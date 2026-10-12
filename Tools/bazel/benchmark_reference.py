#!/usr/bin/env python3
"""Admit the published Q153 measurements without rebuilding or running a reference."""

import argparse
import ast
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

SOURCE = '15361ce5f55a6b8ab3242e89650a188766b47581'
ARCHIVE_SHA256 = '303f1e8a9f3b36507db196dddad6e8937be88b060c8ae46052662610d371eae7'
ASSET_ID = 595991213
TAG = 'layer-runtime-15361ce5f55a-aca1f5691d77'
NAME = 'historical-container-benchmark-15361ce5.zip'
CACHE = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/benchmark-references' / ARCHIVE_SHA256 / NAME
# Canonical AST hashes generated from the authentic SOURCE commit, not the candidate.
RUNTIME_WORKLOAD_SHA256 = '6698993abe3cd493fe8d4c5e7494341b1c3ff1945c95ac1f29f31056f1956c7d'
RUNTIME_CONTRACTS = {
    'run_lane': RUNTIME_WORKLOAD_SHA256,
    'start_lane': '4634336a4b81c780a5baeb194b20eaa7c404d1ef425485b6d286b3eb25d55c1e',
    'RuntimeRunner.command': '8ee415eec636bea718d55b7388eeb71ddb16cdad129c33e52b194f1a987b7ba8',
}
RUNNER_CONTRACT = {'Runner.run': '74916e9d1f025ae7bd22aac3f2dae2df446f6e063fa7ac6bdb5cbe32b35d03cf'}
# Exact reviewed cancellation-only revision; successful timing remains identical.
RUNNER_CANCELLATION_SHA256 = '6ac7f2fe250c711c0bc76c1888d9d5d53fe35babd4b39b1ccbe9e50169f53a65'


def read(path: Path) -> dict:
    """The pinned public archive is authority; never accept edited local measurements."""
    if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise RuntimeError('Historical benchmark archive differs from the published digest')
    with zipfile.ZipFile(path) as archive:
        if sorted(archive.namelist()) != ['benchmark.json', 'manifest.json']:
            raise RuntimeError('Historical benchmark archive members changed')
        result = json.loads(archive.read('benchmark.json'))
    if result.get('source') != SOURCE or result.get('historical') is not True:
        raise RuntimeError('Historical benchmark source identity changed')
    return result


def fetch(destination: Path = CACHE) -> dict:
    """Download the exact asset once, then verify its immutable digest on each reuse."""
    if destination.exists() or destination.is_symlink():
        return read(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.reference-', dir=destination.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            subprocess.run(['gh', 'api', '--hostname', 'github.com',
                            f'repos/stephenlclarke/container/releases/assets/{ASSET_ID}',
                            '-H', 'Accept: application/octet-stream'], stdout=stream,
                           stdin=subprocess.DEVNULL, check=True, timeout=120)
        result = read(Path(temporary))
        os.replace(temporary, destination)
        return result
    finally:
        Path(temporary).unlink(missing_ok=True)


def runtime_samples(reference: dict, fixtures: tuple[str, ...], trials: int) -> list[dict]:
    """Keep every original sample; mismatched trial protocols cannot be replayed."""
    if trials != reference['protocol']['runtimeTrials']:
        raise RuntimeError('Historical runtime benchmark trial count differs')
    rows = [dict(row) for row in reference['runtime']['raw'] if row['lane'] == 'stock']
    if len(rows) != len(fixtures) * trials or {row['fixture'] for row in rows} != set(fixtures):
        raise RuntimeError('Historical runtime workloads are incomplete')
    for fixture in fixtures:
        selected = [row for row in rows if row['fixture'] == fixture]
        if (len(selected) != trials or {row['trial'] for row in selected} != set(range(1, trials + 1))
                or any(row['status'] != 0 or not math.isfinite(row['seconds']) or row['seconds'] <= 0 for row in selected)):
            raise RuntimeError('Historical runtime samples are incomplete or failed')
    for row in rows:
        row.update(historical=True, reference_archive_sha256=ARCHIVE_SHA256,
                   log=f'{NAME}:benchmark.json/runtime/raw')
    return rows


def canonical_ast(node: ast.AST) -> str:
    """Serialize explicit fields, independent of ast.dump's Python-version formatting."""
    def encode(value):
        if isinstance(value, ast.AST):
            # Python 3.12 added type_params; an absent or empty list means no generics.
            fields = {name: encode(item) for name, item in ast.iter_fields(value)
                      if not (name == 'type_params' and item == [])}
            return {'node': type(value).__name__, 'fields': fields}
        if isinstance(value, list):
            return [encode(item) for item in value]
        # Typed repr also preserves bytes, complex constants and None in ordered lists.
        return {'scalar': type(value).__name__, 'value': repr(value)}
    return json.dumps(encode(node), sort_keys=True, separators=(',', ':'))


def workload_digest(name: str, node: ast.AST) -> str:
    """Admit one finite cleanup correction without ignoring any AST fields."""
    observed = hashlib.sha256(canonical_ast(node).encode()).hexdigest()
    if name == 'Runner.run' and observed == RUNNER_CANCELLATION_SHA256:
        return RUNNER_CONTRACT[name]
    return observed


def validate_contract(source: Path, contracts: dict[str, str]) -> None:
    """Bind original setup, output validation and timing code independently of reporting."""
    tree = ast.parse(source.read_text())
    for name, expected in contracts.items():
        nodes = tree.body
        for part in name.split('.'):
            selected = [node for node in nodes if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name == part]
            if len(selected) != 1:
                raise RuntimeError('Runtime workload definition changed: ' + name)
            node = selected[0]
            nodes = node.body
        if workload_digest(name, node) != expected:
            raise RuntimeError('Runtime workload differs from the retained reference: ' + name)


def validate_runtime(reference: dict, source: Path, image: str, fingerprint: dict) -> None:
    """Fail closed on changed workload or host; old results are never recaptured implicitly."""
    validate_contract(source, RUNTIME_CONTRACTS)
    validate_contract(source.with_name('fork_benchmark.py'), RUNNER_CONTRACT)
    old = reference['runtimeLaneFingerprints']['stock']
    if image != old['workload_image'] or fingerprint['kernel_sha256'] != old['kernel_sha256']:
        raise RuntimeError('Runtime image or kernel differs from the retained reference')
    host = reference['phaseHosts']['runtimeBenchmark']
    commands = {'model': ['sysctl', '-n', 'hw.model'], 'memoryBytes': ['sysctl', '-n', 'hw.memsize'],
                'macOSVersion': ['sw_vers', '-productVersion'], 'macOSBuild': ['sw_vers', '-buildVersion'],
                'architecture': ['uname', '-m']}
    for key, command in commands.items():
        observed = subprocess.check_output(command, text=True, timeout=10).strip()
        if observed != str(host[key]):
            raise RuntimeError('Historical runtime host differs: ' + key)
    power = subprocess.check_output(['pmset', '-g', 'batt'], text=True, timeout=10)
    if host.get('powerSource') != 'AC' or "Now drawing from 'AC Power'" not in power:
        raise RuntimeError('Historical runtime host differs: power source')


def retain(evidence: Path, reference: dict) -> None:
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'historical-reference.json').write_text(json.dumps({
        'schema': 1, 'source': SOURCE, 'repository': 'stephenlclarke/container', 'tag': TAG,
        'assetId': ASSET_ID, 'archiveSHA256': ARCHIVE_SHA256, 'historical': True,
        'referenceRebuilt': False, 'referenceRerun': False,
        'identityLimit': reference['identityLimit'],
        'reference': reference,
    }, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    retain(args.evidence, fetch())
