"""Bind unchanged component measurements to the published Q153 reference."""

import ast
import hashlib
import math
from pathlib import Path
import subprocess

from benchmark_reference import ARCHIVE_SHA256, SOURCE

RECIPE_FILES = ('.bazelrc', 'MODULE.bazel', 'MODULE.bazel.lock',
                'Tools/bazel/dependencies.bzl', 'Tools/bazel/layers.bzl',
                'Tools/bazel/layer_build.bzl', 'Tools/bazel/test_inputs.bzl')
WORKLOAD_UNITS = ('prepare', 'Runner.run', 'Runner.bazel', 'Runner.cli',
                  'Runner.builder', 'Runner.tls')


def command(arguments: list[str], root: Path) -> str:
    return subprocess.check_output(arguments, cwd=root, text=True, timeout=60).strip()


def original(root: Path, name: str) -> bytes:
    return subprocess.check_output(['git', 'show', SOURCE + ':' + name], cwd=root, timeout=60)


def units(source: str) -> dict[str, str]:
    tree = ast.parse(source)
    result = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in WORKLOAD_UNITS:
            result[node.name] = ast.dump(node, include_attributes=False)
        elif isinstance(node, ast.ClassDef) and node.name == 'Runner':
            for method in node.body:
                name = 'Runner.' + getattr(method, 'name', '')
                if name in WORKLOAD_UNITS:
                    result[name] = ast.dump(method, include_attributes=False)
    if set(result) != set(WORKLOAD_UNITS):
        raise RuntimeError('Component workload implementation is incomplete')
    return result


def validate_inputs(reference: dict, pairs: dict, root: Path, bazel_sha256: str) -> list[str]:
    """Only Container may change in this bounded candidate-only measurement path."""
    inputs = reference['componentInputs']
    if set(inputs) != set(pairs):
        raise RuntimeError('Historical component inventory differs')
    changed = []
    for name, pair in pairs.items():
        if pair['stock'] != inputs[name]['stock']['revision']:
            raise RuntimeError('Historical upstream component pin differs: ' + name)
        if pair['fork'] != inputs[name]['fork']['revision']:
            if name != 'container':
                raise RuntimeError('Changed dependency needs a reviewed candidate-only benchmark path: ' + name)
            changed.append(name)
    toolchain = reference['componentToolchain']
    if hashlib.sha256((root / 'Package.resolved').read_bytes()).hexdigest() != toolchain['thirdPartyLockSHA256']:
        raise RuntimeError('Historical component dependency lock differs')
    current_patches = {str(path.relative_to(root)) for path in (root / 'Tools/bazel').glob('*.patch')}
    prior_patches = set(command(['git', 'ls-tree', '-r', '--name-only', SOURCE, 'Tools/bazel'], root).splitlines())
    prior_patches = {name for name in prior_patches if name.endswith('.patch')}
    if current_patches != prior_patches:
        raise RuntimeError('Historical component patch inventory differs')
    recipes = [*RECIPE_FILES, *sorted(current_patches)]
    for name in recipes:
        if (root / name).read_bytes() != original(root, name):
            raise RuntimeError('Historical component build recipe differs: ' + name)
    old = original(root, 'Tools/bazel/fork_benchmark.py').decode()
    if units(old) != units((root / 'Tools/bazel/fork_benchmark.py').read_text()):
        raise RuntimeError('Historical component workload or timing boundary differs')
    old_pairs = next(ast.literal_eval(node.value) for node in ast.parse(old).body
                     if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'PAIRS' for t in node.targets))
    for name, pair in pairs.items():
        for field in ('products', 'tests'):
            if pair.get(field) != old_pairs[name].get(field):
                raise RuntimeError('Historical component fixture inventory differs: ' + name)
    for name in ('OCI_FILES', 'TLS_CASES'):
        def constant(source):
            return next(ast.literal_eval(node.value) for node in ast.parse(source).body
                        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets))
        if constant(old) != constant((root / 'Tools/bazel/fork_benchmark.py').read_text()):
            raise RuntimeError('Historical component source fixture selection differs: ' + name)
    swift = command(['xcrun', 'swift', '--version'], root)
    if (bazel_sha256 != toolchain['bazelSHA256'] or toolchain['swiftVersion'] not in swift
            or toolchain['swiftTarget'] not in swift):
        raise RuntimeError('Historical component compiler differs')
    host = reference['phaseHosts']['runtimeBenchmark']
    for key, args in {'model': ['sysctl', '-n', 'hw.model'],
                      'memoryBytes': ['sysctl', '-n', 'hw.memsize'],
                      'macOSVersion': ['sw_vers', '-productVersion'],
                      'macOSBuild': ['sw_vers', '-buildVersion'],
                      'architecture': ['uname', '-m']}.items():
        if command(args, root) != str(host[key]):
            raise RuntimeError('Historical component host differs: ' + key)
    if host.get('powerSource') != 'AC' or "Now drawing from 'AC Power'" not in command(['pmset', '-g', 'batt'], root):
        raise RuntimeError('Historical component host differs: power source')
    return changed


def retained_rows(reference: dict, changed: list[str]) -> tuple[list[dict], list[dict]]:
    """Old failures stay historical; these records are never fresh test results."""
    raw = reference['components']['raw']
    differences = reference['components']['knownCompatibilityDifferences']
    expected_failures = {(r['component'], r['lane'], r['fixture'], r['trial']): r for r in differences}
    identities = set()
    if len(raw) != 236:
        raise RuntimeError('Historical component measurements are incomplete')
    for row in raw:
        key = (row['component'], row['lane'], row['fixture'], row['trial'])
        if key in identities or row['lane'] not in ('stock', 'fork'):
            raise RuntimeError('Historical component measurement identity is duplicated')
        identities.add(key)
        if not math.isfinite(row['seconds']) or row['seconds'] <= 0:
            raise RuntimeError('Historical component measurement is invalid')
        if row['status'] and row != expected_failures.get(key):
            raise RuntimeError('Historical component failure is unreviewed')
    if not set(expected_failures) <= identities:
        raise RuntimeError('Historical compatibility evidence is incomplete')
    selected = [dict(row, historical=True, reference_archive_sha256=ARCHIVE_SHA256)
                for row in raw if row['component'] not in changed or row['lane'] == 'stock']
    historical_differences = [dict(row, historical=True) for row in differences if row['component'] not in changed]
    return selected, historical_differences


def retained_go(reference: dict) -> list[dict]:
    rows = reference['components']['goRaw']
    names = {row['fixture'] for row in reference['components']['goMatrix']}
    expected = {(lane, name, trial) for lane in ('stock', 'fork') for name in names for trial in range(3)}
    actual = {(row['lane'], row['fixture'], row['trial']) for row in rows}
    if len(rows) != 24 or len(names) != 4 or actual != expected:
        raise RuntimeError('Historical Go measurement inventory differs')
    if any(row['iterations'] != 1024 or not math.isfinite(row['ns_per_op']) or row['ns_per_op'] <= 0 for row in rows):
        raise RuntimeError('Historical Go measurements are invalid')
    return [dict(row, historical=True, reference_archive_sha256=ARCHIVE_SHA256) for row in rows]


def require_candidate_rows(rows: list[dict], changed: list[str], pairs: dict) -> None:
    """An incomplete candidate must not pass on the strength of retained dependencies."""
    for component in changed:
        selected = [row for row in rows if row['component'] == component]
        expected = {'prepare-build': 1, 'cached-build': 3, 'component-recompile': 1,
                    'cleanup-bazel': 1, 'cli-run-help': 11, 'cli-version': 11,
                    **{name: 3 for name in pairs[component]['tests']}}
        if {row['fixture'] for row in selected} != set(expected) or any(row['lane'] != 'fork' for row in selected):
            raise RuntimeError('Candidate component fixture inventory is incomplete: ' + component)
        for fixture, count in expected.items():
            measurements = [row for row in selected if row['fixture'] == fixture]
            if fixture in pairs[component]['tests'] and any(row['status'] for row in measurements):
                count = len(measurements)  # The existing suite stops after its first failure.
                if not 1 <= count <= 3:
                    raise RuntimeError('Candidate test trial count is invalid')
            if (len(measurements) != count or {row['trial'] for row in measurements} != set(range(count))
                    or any(not math.isfinite(row['seconds']) or row['seconds'] <= 0 for row in measurements)):
                raise RuntimeError('Candidate component measurements are incomplete: ' + fixture)
