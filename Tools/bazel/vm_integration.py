#!/usr/bin/env python3
"""Qualify the pinned containerization VM suite in an isolated, stable installation."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

from fork_benchmark import ROOT, STORAGE, Runner, digest, install_signal_handlers
from artifacts import native_consumer, native_evidence, native_layers
from runtime_benchmark import IDENTITY, INSTALLS, build_environment, checked, copy_replacing, own, verified_guest

GPU_SKIPS = {
    'container virtio graphics device attachment',
    'container virtio graphics non-root render access',
}
GPU_SKIP_REASON = 'the selected Linux guest kernel does not expose the virtio-GPU render node /dev/dri/renderD128'


def processes(executables: set[str]) -> dict[int, tuple[str, str]]:
    rows = checked(['ps', '-axo', 'pid=,lstart=,comm=']).splitlines()
    return {int(parts[0]): (parts[6], ' '.join(parts[1:6])) for row in rows
            if len(parts := row.strip().split(None, 6)) == 7 and parts[6] in executables}


def retain_results(log: Path, evidence: Path) -> dict:
    text = log.read_text()
    totals = re.search(r'Integration suite completed in ([\d.]+)s with (\d+)/(\d+) passed(?: and (\d+)/\d+ skipped)?', text)
    if not totals or int(totals[3]) == 0:
        raise RuntimeError('VM suite omitted a nonempty completion result')
    suite = ET.Element('testsuite', name='containerization-vm')
    completed = re.findall(r'test (.+) complete in ([\d.]+(?:[eE][+-]?\d+)?)s\.', text)
    for name, seconds in completed:
        ET.SubElement(suite, 'testcase', name=name, time=seconds)
    skips = []
    current = None
    # The driver fixes max-concurrency to one, so a skip belongs to the last
    # started test. Retain its name instead of conflating identical reasons.
    for line in text.splitlines():
        started = re.search(r'test (.+) started\.\.\.$', line)
        skipped = re.search(r'skipped test: (.+)$', line)
        if started:
            current = started[1]
        elif skipped:
            if current is None:
                raise RuntimeError('VM skip has no test identity')
            skips.append({'test': current, 'reason': skipped[1]})
            ET.SubElement(ET.SubElement(suite, 'testcase', name=current), 'skipped', message=skipped[1])
            current = None
        elif re.search(r'test .+ (?:complete in|failed:)', line):
            current = None
    failures = re.findall(r'test (.+) failed: (.+)', text)
    for name, error in failures:
        ET.SubElement(ET.SubElement(suite, 'testcase', name=name), 'failure', message=error)
    ET.ElementTree(suite).write(evidence / 'tests.xml', encoding='unicode')
    result = {'passed_tests': int(totals[2]), 'total_tests': int(totals[3]),
              'skipped_tests': int(totals[4] or 0), 'skips': skips}
    if (len(completed) != result['passed_tests'] or len(skips) != result['skipped_tests']
            or len(suite) != result['total_tests']):
        raise RuntimeError('VM individual results disagree with the completion totals')
    return result


def validate_skips(result: dict) -> None:
    if any(skip['test'] not in GPU_SKIPS or skip['reason'] != GPU_SKIP_REASON for skip in result['skips']):
        raise RuntimeError('VM suite skipped required tests; see named skip reasons in vm-integration.json')


def stage_runc(guest: dict, binaries: Path) -> dict:
    """The host presence check must name the binary included in this exact guest."""
    pin = guest['identity'].get('runc')
    if not pin or not guest.get('runc_binary'):
        raise RuntimeError('VM qualification requires a guest built with guest_artifact.py --with-runc')
    source = Path(guest['runc_binary'])
    if source.is_symlink() or digest(source) != pin['sha256'] or guest['binaries'].get('runc') != pin['sha256']:
        raise RuntimeError('VM runc fixture differs from the guest artifact')
    destination = binaries / 'runc-arm64'
    copy_replacing(source, destination)
    destination.chmod(0o755)
    if digest(destination) != pin['sha256']:
        raise RuntimeError('Staged VM runc fixture changed')
    return pin


def vm_build_plan(root: Path, guest_source: str) -> tuple[list[str], list[str], dict]:
    """Keep the changed SDK source-built while admitting its exact lower prefix."""
    if native_layers.pin_records(root)['containerization']['state']['revision'] != guest_source:
        raise ValueError('VM guest source differs from selected SDK')
    admission = native_layers.import_layers(root, groups=('foundation',))
    if (set(admission['layers']) != {'argument-parser', 'foundation'}
            or '+dependencies+swiftpkg_containerization' in admission['overrides']):
        raise ValueError('VM tools require a source-built SDK and only its lower prefix')
    labels = ['@swiftpkg_containerization//:' + name + '.rspm'
              for name in ('cctl', 'containerization-integration')]
    return labels, ['--config=release', *native_layers.bazel_flags(admission)], admission


def verify_vm_actions(graph: dict, admission: dict, loaded: dict[str, str]) -> dict:
    """Cache hits cannot hide lower source compilation or omit a changed SDK tool."""
    imported = set(admission['overrides'])
    if not imported or set(loaded) != imported:
        raise ValueError('VM graph has no exact loaded repository set')
    targets = {row['id']: row['label'] for row in graph['targets']}
    required = {'@@+dependencies+swiftpkg_containerization//:' + name + '.rspm.__impl'
                for name in ('cctl', 'containerization-integration')}
    links, compiled, actions = set(), 0, {}
    for action in graph['actions']:
        label = targets.get(action['targetId'])
        if label is None:
            raise ValueError('VM action owner target is missing')
        if label.startswith('@@+dependencies+swiftpkg_'):
            canonical = label.split('//', 1)[0].removeprefix('@@')
            if canonical == '+dependencies+swiftpkg_containerization':
                compiled += action['mnemonic'] == 'SwiftCompile'
            elif (canonical not in imported
                  or action['mnemonic'] not in native_consumer.ALLOWED_IMPORTED_ACTIONS):
                raise ValueError('VM dependency source action remains reachable: ' + label)
            else:
                actions[action['mnemonic']] = actions.get(action['mnemonic'], 0) + 1
        if action['mnemonic'] == 'CppLink' and label in required:
            if label in links:
                raise ValueError('VM tool links more than once')
            links.add(label)
    if links != required or not compiled:
        raise ValueError('VM graph omitted a source-built SDK tool')
    return {'sdkCompileActions': compiled, 'links': sorted(links),
            'importedActions': actions, 'loadedBUILD': loaded}


def compile_vm_tools(runner: Runner, evidence: Path, guest_source: str) -> dict[str, Path]:
    """Retain build outputs and prove both tools use one verified dependency vector."""
    labels, flags, admission = vm_build_plan(ROOT, guest_source)
    launcher = str(ROOT / 'Tools/bazel/run.sh')
    (evidence / 'native-lower-admission.json').write_text(json.dumps(admission, indent=2) + '\n')
    row = runner.run('vm', 'fork', 'build', 0, [launcher, 'build', *labels, *flags], ROOT, 1800)
    if row['status']:
        raise RuntimeError('VM integration compilation failed')
    logs = re.findall(r'^Evidence: (/.+\.log)$', Path(row['log']).read_text(), re.M)
    if len(logs) != 1:
        raise ValueError('VM build lacks one retained Bazel evidence log')
    raw = Path(logs[0])
    for suffix in ('.log', '.events.json', '.source.txt', '.diff', '.inputs.sha256'):
        shutil.copy2(raw.with_suffix(suffix), evidence / ('vm-source-build' + suffix))
    env = build_environment()
    base = Path(checked([launcher, 'info', 'output_base'], cwd=ROOT, env=env).splitlines()[-1])
    execution = Path(checked([launcher, 'info', 'execution_root'], cwd=ROOT, env=env).splitlines()[-1])
    loaded = native_layers.verify_loaded_repositories(admission, base)
    binaries = {}
    selected = {}
    for name, label in zip(('cctl', 'containerization-integration'), labels):
        queried = runner.run('vm', 'fork', 'query-' + name, 0,
                             [launcher, 'cquery', label, *flags, '--output=files'], ROOT, 120)
        if queried['status']:
            raise RuntimeError('VM configured output query failed')
        paths = [line for line in Path(queried['log']).read_text().splitlines()
                 if line.startswith('bazel-out/') and line.endswith('/' + name + '.rspm.__impl')
                 and '/Contents/Resources/DWARF/' not in line]
        if len(paths) != 1:
            raise ValueError('VM configured executable selection is ambiguous')
        binaries[name] = selected[paths[0]] = execution / paths[0]
    build = native_evidence.verify_build(evidence / 'vm-source-build.events.json', labels,
                                        required_files=selected, expected_options=flags)
    queried = runner.run('vm', 'fork', 'action-graph', 0,
                         [launcher, 'aquery', 'deps(set(' + ' '.join(labels) + '))', *flags,
                          '--output=jsonproto', '--include_artifacts=true',
                          '--include_commandline=true'], ROOT, 120)
    if queried['status']:
        raise RuntimeError('VM action graph query failed')
    graph_path = Path(queried['log'])
    graph = verify_vm_actions(native_consumer._graph(graph_path), admission, loaded)
    harness = {name: digest(ROOT / name) for name in
               ('Tools/bazel/vm_integration.py', 'Tools/bazel/test_vm_integration.py')}
    snapshot = native_evidence.verify_source_snapshot(
        evidence / 'vm-source-build.events.json', admission['source'], ROOT,
        {**admission['recipeSHA256'], **harness})
    proof = {'source': admission['source'], 'sdk': guest_source, 'passed': True,
             'sourceSnapshot': snapshot, 'harnessSHA256': harness,
             'build': build, 'graph': graph, 'actionGraphSHA256': digest(graph_path),
             'admissionSHA256': digest(evidence / 'native-lower-admission.json'),
             'unsignedBinaries': {name: digest(path) for name, path in binaries.items()}}
    (evidence / 'vm-build.json').write_text(json.dumps(proof, indent=2) + '\n')
    return binaries


def private_child(parent: Path, name: str) -> Path:
    """Reject redirected staging/state paths before creating or writing them."""
    child = parent / name
    if (child.is_symlink() or child.resolve().parent != parent.resolve()
            or (child.exists() and (not child.is_dir() or child.stat().st_uid != os.getuid()))):
        raise RuntimeError('VM child is not a private owned directory: ' + str(child))
    child.mkdir(mode=0o700, exist_ok=True)
    return child


def remove_run_home(parent: Path, home: Path) -> None:
    """Remove only the fresh, marked state belonging to this invocation."""
    if home.parent != parent or not home.name.startswith('run-'):
        raise RuntimeError('VM run home escaped its installation')
    private_child(parent, home.name)
    marker = home / '.runtime-benchmark-owner.json'
    expected = {'owner': 'container-runtime-benchmark', 'lane': 'containerization-integration-state', 'schema': 1}
    if marker.is_symlink() or not marker.is_file() or json.loads(marker.read_text()) != expected:
        raise RuntimeError('VM run home has no matching ownership marker')
    shutil.rmtree(home)


def run(evidence: Path, guest_receipt: Path, selection: str | None) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    result = {'passed': False, 'selection': selection, 'failures': []}
    directory = INSTALLS / 'containerization-integration'
    own(directory, 'containerization-integration')
    binaries = private_child(directory, 'bin')
    home = None
    executables = {str(binaries / name) for name in ('cctl', 'containerization-integration')}
    runner = Runner(evidence, STORAGE)
    with (INSTALLS / 'benchmark.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if processes(executables):
            raise RuntimeError('The private VM integration installation is already active')
        try:
            guest = verified_guest(guest_receipt)
            result['runc'] = stage_runc(guest, binaries)
            shutil.copy2(guest_receipt, evidence / 'guest-artifact.json')
            compiled = compile_vm_tools(runner, evidence, guest['identity']['source'])
            result['build_proof_sha256'] = digest(evidence / 'vm-build.json')
            for name, source in compiled.items():
                destination = binaries / name
                copy_replacing(source, destination)
                destination.chmod(0o755)
                checked(['codesign', '--force', '--sign', IDENTITY, '--timestamp=none', '--options', 'runtime',
                         '--identifier', 'io.github.stephenlclarke.' + name,
                         '--entitlements', str(ROOT / 'signing/container-runtime-linux.entitlements'), str(destination)])
            kernel = INSTALLS / 'assets/opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug'
            if not kernel.exists():
                raise RuntimeError('Prepare the qualified kernel assets before VM integration')
            copy_replacing(kernel, binaries / 'vmlinux-arm64')
            home = directory / ('run-' + uuid.uuid4().hex[:12])
            own(home, 'containerization-integration-state')
            temporary = private_child(home, 'tmp')
            runner.env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(temporary) + '/')
            probe = runner.run('vm', 'fork', 'home-isolation', 0,
                               ['xcrun', 'swift', '-e', 'import Foundation; print(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path)'],
                               directory, 30)
            observed = Path(Path(probe['log']).read_text().strip())
            if probe['status'] or observed.resolve() != (home / 'Library/Application Support').resolve():
                raise RuntimeError('Foundation did not honor the private integration home')
            result.update(source=guest['identity']['source'], kernel_sha256=digest(kernel),
                          binaries={name: digest(Path(name)) for name in executables}, isolated_home=str(home))
            for fixture, args in [('load-init', ['images', 'load', '--input', guest['archive']]),
                                  ('tag-init', ['images', 'tag', guest['reference'], 'vminit:latest'])]:
                row = runner.run('vm', 'fork', fixture, 0, [str(binaries / 'cctl'), *args], directory, 120)
                if row['status']:
                    raise RuntimeError('VM init preparation failed: ' + fixture)
            # A prior init.block must never mask a changed source-built guest.
            (binaries / 'init.block').unlink(missing_ok=True)
            args = [str(binaries / 'containerization-integration'), '--kernel', str(binaries / 'vmlinux-arm64'),
                    '--max-concurrency', '1', '--bootlog-dir', str(evidence / 'bootlogs')]
            if selection:
                args += ['--filter', selection]
            row = runner.run('vm', 'fork', 'integration', 0, args, directory, 1800)
            result.update(retain_results(Path(row['log']), evidence))
            validate_skips(result)
            if row['status'] or result['passed_tests'] + result['skipped_tests'] != result['total_tests']:
                raise RuntimeError('Containerization VM suite failed')
            panics = [str(path) for path in (evidence / 'bootlogs').glob('*.log')
                      if re.search(r'Kernel panic|Oops:', path.read_text(errors='replace'))]
            if panics:
                raise RuntimeError('Guest kernel fault in boot logs: ' + str(panics))
            result['passed'] = True
        except BaseException as error:
            result['failures'].append(str(error))
            raise
        finally:
            leaked = processes(executables)
            for number in (signal.SIGTERM, signal.SIGKILL):
                for pid, executable in leaked.items():
                    if processes(executables).get(pid) == executable:
                        try:
                            os.kill(pid, number)
                        except ProcessLookupError:
                            pass
                if processes(executables):
                    time.sleep(.5)
            if leaked:
                result['passed'] = False
                result['failures'].append('VM suite left running private children: ' + str(sorted(leaked)))
            result['cleanup_complete'] = not processes(executables)
            if result['cleanup_complete']:
                try:
                    if home is not None:
                        if result['passed']:
                            remove_run_home(directory, home)
                        else:
                            result['retained_failed_home'] = str(home)
                    (binaries / 'init.block').unlink(missing_ok=True)
                except (OSError, RuntimeError) as error:
                    result['cleanup_complete'] = False
                    result['passed'] = False
                    result['failures'].append('VM artifact cleanup failed: ' + str(error))
            (evidence / 'vm-integration.json').write_text(json.dumps(result, indent=2) + '\n')
    if not result['passed'] or not result['cleanup_complete']:
        raise RuntimeError('VM integration or cleanup failed')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--guest-artifact', type=Path, required=True)
    parser.add_argument('--filter')
    args = parser.parse_args()
    run(args.evidence, args.guest_artifact, args.filter)


if __name__ == '__main__':
    main()
