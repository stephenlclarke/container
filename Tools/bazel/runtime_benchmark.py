#!/usr/bin/env python3
"""Build-end runtime comparison using isolated data and stable signed binaries."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import xml.etree.ElementTree as ET

from fork_benchmark import BAZEL, BAZEL_SHA, PAIRS, ROOT, STORAGE, Runner, digest, prepare, install_signal_handlers
from bazel_environment import bazel_environment

INSTALLS = Path.home() / 'Library/Application Support/ContainerFamily/benchmarks/runtime'
STATE = Path('/private/tmp') / f'cfb-{os.getuid()}'
IDENTITY = 'BDDA5D3A8836437C2EFA24CDACE0FEBFBEF20633'
NAMESPACE = 'io.github.stephenlclarke.container.benchmark'
ALPINE = 'docker.io/library/alpine@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8'
STOCK_INIT = 'ghcr.io/apple/containerization/vminit@sha256:4c1836052eafcbc944c403fb23ded06562962d2402c9dcc651495a32300614df'
BUILDERS = {
    'stock': 'ghcr.io/apple/container-builder-shim/builder@sha256:b5b3f7fa81e662db6929f1ad66d835d151a1b03f682cfe5f9fcb17fa46d6bcc9',
}
PLUGINS = {
    'container-runtime-linux': 'RuntimeLinux', 'container-network-vmnet': 'NetworkVmnet',
    'container-core-images': 'CoreImages', 'machine-apiserver': 'MachineAPIServer', 'k8s': 'K8s',
}
FIXTURES = ('start-exit', 'warm-exec', 'sha256-128m', 'write-sync-64m',
            'image-save', 'image-load-warm', 'build-no-cache', 'build-cached')
KERNEL_SHA = '8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5'
KERNEL_MEMBER = './opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug'


def verified_guest(receipt: Path, workspace: Path = ROOT) -> dict:
    """Bind the exact init archive to the consumer's locked guest source."""
    record = json.loads(receipt.read_text())
    pin = next(p['state']['revision'] for p in json.loads((workspace / 'Package.resolved').read_text())['pins']
               if p['identity'] == 'containerization')
    if record.get('schema') != 1 or record['identity']['source'] != pin:
        raise RuntimeError('Guest artifact source does not match the container dependency lock')
    if record['reference'].rsplit(':', 1)[-1] != pin or digest(Path(record['archive'])) != record['archive_sha256']:
        raise RuntimeError('Guest artifact reference or archive checksum changed')
    return record


def verified_builder(receipt: Path) -> dict:
    from builder_artifact import source_pin
    record = json.loads(receipt.read_text())
    if record.get('schema') != 1 or record['identity']['source'] != source_pin():
        raise RuntimeError('Builder artifact source does not match the container manifest')
    if digest(Path(record['archive'])) != record['archive_sha256']:
        raise RuntimeError('Builder artifact archive checksum changed')
    return record


def environment(lane: str) -> dict:
    state = STATE / lane
    return dict(os.environ, CONTAINER_APP_ROOT=str(state / 'app'),
                CONTAINER_INSTALL_ROOT=str(INSTALLS / lane / 'install'),
                CONTAINER_SERVICE_NAMESPACE=NAMESPACE if lane == 'fork' else 'com.apple.container',
                XDG_CONFIG_HOME=str(state / 'xdg'), CI='1')


def build_environment() -> dict:
    return bazel_environment(os.environ)


def services(prefix: str) -> list[tuple[str, str]]:
    return [(parts[0], parts[2]) for line in checked(['launchctl', 'list']).splitlines()
            if len(parts := line.split()) == 3 and parts[2].startswith(prefix)]


def service_is_inactive(description: str) -> bool:
    """Inspect the top-level state; a PID gap during respawn is not inactivity."""
    return (re.search(r'^\tstate = not running$', description, re.M) is not None
            and re.search(r'^\tpid = ', description, re.M) is None)


def stop_owned(lane: str, *, originals: list[dict] | None = None) -> None:
    prefix = (NAMESPACE if lane == 'fork' else 'com.apple.container') + '.'
    install = str(INSTALLS / lane / 'install') + '/'
    preserved = set()
    for _, label in services(prefix):
        target = f'gui/{os.getuid()}/{label}'
        try:
            description = checked(['launchctl', 'print', target])
        except subprocess.CalledProcessError:
            if label not in {name for _, name in services(prefix)}:
                continue  # An auto-removed workload finished between list and print.
            raise
        program = re.search(r'^\s*program = (.+)$', description, re.M)
        if not program or not program[1].startswith(install):
            original = next((row for row in originals or [] if row['label'] == label), None)
            path = re.search(r'^\s*path = (.+)$', description, re.M)
            if (original is not None and path is not None and path[1] == original['path']
                    and digest(Path(path[1])) == original['sha256']):
                preserved.add(label)
                continue
            raise RuntimeError(f'Refusing to stop unrelated service {label}')
        try:
            checked(['launchctl', 'bootout', target])
        except subprocess.CalledProcessError:
            if label in {name for _, name in services(prefix)}:
                raise
    deadline = time.monotonic() + 5
    while any(label not in preserved for _, label in services(prefix)):
        if time.monotonic() >= deadline:
            raise RuntimeError(f'Benchmark services survived cleanup: {prefix}')
        time.sleep(0.1)


class StockSlot:
    """Temporarily unload inactive Apple-name registrations; never overwrite their files."""
    def __init__(self, evidence: Path) -> None:
        self.evidence = evidence
        self.saved: list[dict] = []

    def acquire(self) -> None:
        originals = services('com.apple.container.') + services('sh.brew.container')
        for pid, label in originals:
            if pid != '-':
                raise RuntimeError(f'Existing {label} is active; stock benchmark cannot safely replace it')
            target = f'gui/{os.getuid()}/{label}'
            description = checked(['launchctl', 'print', target], timeout=20)
            if not service_is_inactive(description):
                raise RuntimeError(f'Existing {label} is not inactive; stop it before qualification')
            match = re.search(r'^\s*path = (.+)$', description, re.M)
            if not match:
                raise RuntimeError(f'Cannot preserve registration {label}')
            path = Path(match[1])
            if plistlib.loads(path.read_bytes())['Label'] != label:
                raise RuntimeError(f'Loaded registration and saved plist disagree: {label}')
            self.saved.append(dict(label=label, path=str(path), sha256=digest(path), unloaded=False))
            (self.evidence / (label + '.before.txt')).write_text(description)
            shutil.copy2(path, self.evidence / (label + '.original.plist'))
        self.persist()
        for row in self.saved:
            self.verify_remaining()
            checked(['launchctl', 'bootout', f'gui/{os.getuid()}/{row["label"]}'])
            row['unloaded'] = True
            self.persist()

    def verify_remaining(self) -> None:
        """Reject activation or changed registrations before each displacement."""
        current = {label: pid for pid, label in services('com.apple.container.') + services('sh.brew.container')}
        remaining = [row for row in self.saved if not row['unloaded']]
        if set(current) != {row['label'] for row in remaining}:
            raise RuntimeError('Original service registrations changed before preservation')
        for row in remaining:
            label = row['label']
            if current[label] != '-':
                raise RuntimeError(f'Existing {label} became active before preservation')
            description = checked(['launchctl', 'print', f'gui/{os.getuid()}/{label}'], timeout=20)
            match = re.search(r'^\s*path = (.+)$', description, re.M)
            if not service_is_inactive(description):
                raise RuntimeError(f'Existing {label} is no longer inactive before preservation')
            if match is None or match[1] != row['path'] or digest(Path(row['path'])) != row['sha256']:
                raise RuntimeError(f'Original service registration changed: {label}')

    def persist(self) -> None:
        (self.evidence / 'service-restoration.json').write_text(json.dumps(self.saved, indent=2) + '\n')

    def restore(self) -> None:
        errors = []
        for row in self.saved:
            try:
                if digest(Path(row['path'])) != row['sha256']:
                    raise RuntimeError(f'Original plist changed: {row["path"]}')
                loaded = {label for _, label in services(row['label'])}
                if row['label'] in loaded:
                    description = checked(['launchctl', 'print', f'gui/{os.getuid()}/{row["label"]}'])
                    match = re.search(r'^\s*path = (.+)$', description, re.M)
                    if match is None or match[1] != row['path']:
                        raise RuntimeError('Original service was replaced: ' + row['label'])
                else:
                    checked(['launchctl', 'bootstrap', f'gui/{os.getuid()}', row['path']])
                row['restored'] = True
            except Exception as error:
                errors.append(str(error))
        self.persist()
        if errors:
            raise RuntimeError('; '.join(errors))


class RuntimeRunner(Runner):
    def __init__(self, evidence: Path, scratch: Path) -> None:
        super().__init__(evidence, scratch)
        self.runtime_environment: dict[str, str] = {}

    def command(self, lane: str, fixture: str, trial: int, args: list[str],
                timeout: int = 120, expected: str | None = None) -> dict:
        self.env = dict(environment(lane), **self.runtime_environment)
        cli = INSTALLS / lane / 'install/bin/container'
        row = self.run('runtime-stack', lane, fixture, trial, [str(cli), *args], ROOT, timeout)
        if expected is not None and expected not in Path(row['log']).read_text():
            row['status'] = row['status'] or 65
            row['validation_error'] = f'Expected output missing: {expected}'
        self.report()
        if row['status']:
            raise RuntimeError(f'{lane}/{fixture} failed; see {row["log"]}')
        return row

    def report(self) -> None:
        all_rows = self.rows
        self.rows = [r for r in all_rows if r['fixture'] in FIXTURES]
        super().report()
        self.rows = all_rows
        (self.evidence / 'operations.json').write_text(json.dumps(all_rows, indent=2) + '\n')


def start_lane(runner: RuntimeRunner, lane: str) -> None:
    state = STATE / lane
    own(state, lane)
    metadata = json.loads((runner.evidence / f'{lane}-fingerprint.json').read_text())
    install = INSTALLS / lane / 'install'
    for relative, sha in metadata['binaries'].items():
        if digest(install / relative) != sha:
            raise RuntimeError(f'Binary changed after fingerprint: {lane}/{relative}')
    if digest(state / 'app/kernels/default.kernel-arm64') != metadata['kernel_sha256']:
        raise RuntimeError('Staged kernel changed after fingerprint')
    start = ['system', 'start', '--app-root', str(state / 'app'), '--install-root', str(install),
             '--log-root', str(state / 'logs'), '--disable-kernel-install', '--timeout', '30']
    if lane == 'fork':
        guest = verified_guest(runner.evidence / 'guest-artifact.json')
        if guest['archive_sha256'] != metadata['init_archive_sha256']:
            raise RuntimeError('Guest artifact changed after staging')
        start += ['--init-image-archive', guest['archive']]
    runner.command(lane, 'setup-start', 0, start, 180)
    runner.command(lane, 'setup-images', 0, ['image', 'load', '--input', str(INSTALLS / 'assets/alpine.tar')])
    if lane == 'fork':
        builder = verified_builder(runner.evidence / 'builder-artifact.json')
        if builder['archive_sha256'] != metadata['builder_archive_sha256']:
            raise RuntimeError('Builder artifact changed after staging')
        runner.command(lane, 'setup-builder-image', 0, ['image', 'load', '--input', builder['archive']], 180)


def run_lane(runner: RuntimeRunner, lane: str, trials: int) -> None:
    start_lane(runner, lane)
    state = STATE / lane
    resources = ['--cpus', '1', '--memory', '512m', '--network', 'none']
    runner.command(lane, 'setup-vm', 0, ['run', *resources, '--rm', ALPINE, 'echo', 'runtime-ready'], expected='runtime-ready')
    warm = 'runtime-benchmark-warm'
    runner.command(lane, 'setup-warm', 0, ['run', *resources, '--detach', '--name', warm, ALPINE, 'sleep', '3600'])
    expected_hash = hashlib.sha256(bytes(128 * 1024 * 1024)).hexdigest()
    for trial in range(1, trials + 1):
        runner.command(lane, 'start-exit', trial, ['run', *resources, '--rm', ALPINE, 'true'])
        runner.command(lane, 'warm-exec', trial, ['exec', warm, 'echo', 'exec-ok'], expected='exec-ok')
        runner.command(lane, 'sha256-128m', trial, ['exec', warm, 'sh', '-ec',
                       'dd if=/dev/zero bs=1048576 count=128 2>/dev/null | sha256sum'], expected=expected_hash)
        runner.command(lane, 'write-sync-64m', trial, ['exec', warm, 'sh', '-ec',
                       'dd if=/dev/zero of=/tmp/bench-data bs=1048576 count=64 2>/dev/null; sync; wc -c </tmp/bench-data; rm /tmp/bench-data'], expected='67108864')
        archive_path = state / f'alpine-{trial}.tar'
        if archive_path.exists():
            archive_path.unlink()
        runner.command(lane, 'image-save', trial, ['image', 'save', '--output', str(archive_path), ALPINE])
        runner.command(lane, 'image-load-warm', trial, ['image', 'load', '--input', str(INSTALLS / 'assets/alpine.tar')])
    runner.command(lane, 'cleanup-warm', 0, ['rm', '--force', warm])
    runner.command(lane, 'setup-builder', 0, ['builder', 'start', '--cpus', '2', '--memory', '2g'], 300)
    context = state / 'context'
    context.mkdir(exist_ok=True)
    payload = b'container runtime benchmark\n' * 4096
    (context / 'payload.txt').write_bytes(payload)
    (context / 'Dockerfile').write_text(f'FROM {ALPINE}\nCOPY payload.txt /payload.txt\nRUN sha256sum /payload.txt > /result.txt\n')
    tag = 'runtime-benchmark:result'
    build = ['build', '--progress', 'plain', '--tag', tag, str(context)]
    runner.command(lane, 'setup-build', 0, build, 300)
    for trial in range(1, trials + 1):
        runner.command(lane, 'build-no-cache', trial, [*build[:1], '--no-cache', *build[1:]], 180)
        runner.command(lane, 'build-cached', trial, build, 180)
        runner.command(lane, 'validate-build', trial, ['run', *resources, '--rm', tag, 'cat', '/result.txt'],
                       expected=hashlib.sha256(payload).hexdigest())


def benchmark(evidence: Path, trials: int, reset: bool = False) -> None:
    runner = RuntimeRunner(evidence, STATE)
    slot = StockSlot(evidence)
    failures = []
    (evidence / 'host.json').write_text(json.dumps({
        'system': checked(['sw_vers']), 'hardware': checked(['sysctl', 'hw.model', 'hw.memsize', 'machdep.cpu.brand_string']),
        'power': checked(['pmset', '-g', 'batt']), 'load_average_before': os.getloadavg(),
        'lane_order': ['fork', 'stock'], 'trials': trials,
        'method': 'serial optimized stacks; preloaded image; fresh VM per start; warm host caches; builder 2 CPU/2GiB; workloads 1 CPU/512MiB',
    }, indent=2) + '\n')
    # Serial lanes avoid VM resource contention. Setup and registry traffic are untimed.
    for lane in ('fork', 'stock'):
        acquired = False
        try:
            if lane == 'stock':
                slot.acquire()
                acquired = True
            else:
                stop_owned(lane)
            if reset:
                metadata = json.loads((evidence / (lane + '-fingerprint.json')).read_text())
                if reset_state(lane, metadata['init_image'], metadata['builder_image']) != metadata['kernel_sha256']:
                    raise RuntimeError('Prepared benchmark kernel changed')
            run_lane(runner, lane, trials)
        except Exception as error:
            failures.append(f'{lane}: {error}')
        finally:
            try:
                if lane != 'stock' or acquired:
                    stop_owned(lane)
            except Exception as error:
                failures.append(f'{lane} cleanup: {error}')
            if lane == 'stock':
                try:
                    slot.restore()
                except Exception as error:
                    failures.append(f'stock restoration: {error}')
            logs = STATE / lane / 'logs'
            if logs.exists():
                shutil.copytree(logs, evidence / (lane + '-service-logs'), dirs_exist_ok=True)
    finish(runner, trials, failures)


def finish(runner: RuntimeRunner, trials: int, failures: list[str]) -> None:
    evidence = runner.evidence
    runner.report()
    matrix = json.loads((evidence / 'matrix.json').read_text())
    for lane in ('stock', 'fork'):
        for fixture in FIXTURES:
            rows = [r for r in runner.rows if r['lane'] == lane and r['fixture'] == fixture]
            if len(rows) != trials or {r['trial'] for r in rows} != set(range(1, trials + 1)) or any(r['status'] for r in rows):
                failures.append(f'{lane}/{fixture}: incomplete or failed')
    failures += [f'{r["fixture"]}: timing regression' for r in matrix if not r['passed']]
    (evidence / 'acceptance.json').write_text(json.dumps({'passed': not failures, 'failures': failures}, indent=2) + '\n')
    suite = ET.parse(evidence / 'timings.xml')
    for failure in failures:
        case = ET.SubElement(suite.getroot(), 'testcase', classname='runtime-acceptance', name=failure)
        ET.SubElement(case, 'failure', message=failure)
    suite.write(evidence / 'timings.xml', encoding='unicode')
    with (evidence / 'matrix.md').open('a') as stream:
        stream.write('\nResult: **' + ('FAILED / INCOMPLETE' if failures else 'PASSED') + '**\n')
        stream.write('\nThree trials by default; medians shown. Serial optimized stacks, warm host caches, preloaded identical Alpine image and kernel. No-cache builds reuse the downloaded base image. Ratios describe the whole stack and cannot attribute a difference to an individual dependency.\n')
        stream.write('\nSetup, output checks and cleanup: `operations.json`; exact binaries/images: `*-fingerprint.json`; service restoration: `service-restoration.json`.\n')
        for failure in failures:
            stream.write('\n- ' + failure + '\n')
    if failures:
        raise RuntimeError('\n'.join(failures))


def checked(args: list[str], **kwargs) -> str:
    return subprocess.check_output(args, text=True, timeout=kwargs.pop('timeout', 60), **kwargs).strip()


def own(directory: Path, lane: str) -> None:
    marker = directory / '.runtime-benchmark-owner.json'
    expected = {'owner': 'container-runtime-benchmark', 'lane': lane, 'schema': 1}
    if directory.is_symlink():
        raise RuntimeError(f'Refusing symlinked benchmark directory: {directory}')
    if directory.exists() and (not marker.is_file() or json.loads(marker.read_text()) != expected):
        raise RuntimeError(f'Benchmark directory has no matching ownership marker: {directory}')
    directory.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps(expected) + '\n')


def copy_replacing(source: Path, destination: Path) -> None:
    # Bazel artifacts can be read-only. Replace the staged inode atomically.
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        candidate = Path(temporary.name)
    try:
        shutil.copy2(source, candidate)
        candidate.replace(destination)
    finally:
        candidate.unlink(missing_ok=True)


def reset_state(lane: str, init: str, builder_image: str) -> str:
    """Reset only the marked runtime data; retain installations and compiler caches."""
    state = STATE / lane
    own(state, lane)
    app = state / 'app'
    for directory in (app, state / 'logs'):
        if directory.is_symlink():
            raise RuntimeError(f'Refusing symlinked benchmark data: {directory}')
        if directory.exists():
            shutil.rmtree(directory)
    (app / 'kernels').mkdir(parents=True, exist_ok=True)
    kernel = INSTALLS / 'assets/opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug'
    shutil.copy2(kernel, app / 'kernels/default.kernel-arm64')
    config_dir = state / 'xdg/container'
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / 'config.toml').write_text(
        f'[vminit]\nimage = "{init}"\n\n[build]\nimage = "{builder_image}"\n')
    return digest(kernel)


def stage(lane: str, workspace: Path, output_root: Path, evidence: Path,
          configuration: str = 'release', profile_file: str | None = None) -> None:
    if lane == 'fork':
        guest = verified_guest(evidence / 'guest-artifact.json', workspace)
        builder = verified_builder(evidence / 'builder-artifact.json')
    install = INSTALLS / lane / 'install'
    own(install, lane)
    processes = checked(['ps', '-axo', 'comm=']).splitlines()
    if any(p.startswith(str(install) + '/') for p in processes):
        raise RuntimeError('Stop this benchmark runtime before replacing its binaries')
    env = build_environment()
    revision = checked(['git', 'rev-parse', 'HEAD'], cwd=workspace) if lane == 'fork' else PAIRS['container']['stock']
    env['GIT_COMMIT'] = revision
    bazel = [str(BAZEL), '--output_user_root=' + str(output_root)]
    execution = Path(checked(bazel + ['info', 'execution_root'], cwd=workspace, env=env))
    target = '//:container' if lane == 'fork' else '//:component'
    files = checked(bazel + ['cquery', target, '--config=' + configuration, '--repo_env=GIT_COMMIT=' + revision, '--output=files'],
                    cwd=workspace, env=env).splitlines()
    executables = {Path(p).name.removesuffix('.rspm.__impl'): execution / p
                   for p in files if p.endswith('.rspm.__impl') and '/Contents/Resources/DWARF/' not in p}
    names = ['container', 'container-apiserver', *PLUGINS]
    if lane == 'fork':
        names.append('container-engine')
    fingerprints = {}
    for name in names:
        source = executables[name]
        if name in PLUGINS:
            directory = install / 'libexec/container/plugins' / name
            destination = directory / 'bin' / name
            plugin_source = workspace / 'Sources/Plugins' / PLUGINS[name]
            directory.mkdir(parents=True, exist_ok=True)
            shutil.copy2(plugin_source / 'config.toml', directory / 'config.toml')
            if (plugin_source / 'Resources').exists():
                shutil.copytree(plugin_source / 'Resources', directory / 'resources', dirs_exist_ok=True)
        else:
            destination = install / 'bin' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        destination.chmod(0o755)
        identifier = {'container': 'com.apple.container.cli',
                      'container-apiserver': 'com.apple.container.apiserver',
                      'container-engine': 'io.github.stephenlclarke.container.engine'}.get(name, 'com.apple.container.' + name)
        command = ['codesign', '--force', '--sign', IDENTITY, '--identifier', identifier,
                   '--options', 'runtime', '--timestamp=none']
        entitlement = workspace / 'signing' / (name + '.entitlements')
        if entitlement.exists():
            command += ['--entitlements', str(entitlement)]
        checked(command + [str(destination)])
        checked(['codesign', '--verify', '--strict', str(destination)])
        fingerprints[str(destination.relative_to(install))] = digest(destination)
    if lane == 'fork':
        helpers = install / 'libexec/container/helpers'
        helpers.mkdir(parents=True, exist_ok=True)
        for name in ['container-semantic-helper', 'container-semantic-helper.manifest.json']:
            source = next(execution / p for p in files if p.endswith('/dist/' + name))
            copy_replacing(source, helpers / name)
            fingerprints[str((helpers / name).relative_to(install))] = digest(helpers / name)
    if lane == 'fork':
        products = evidence / 'debug-products'
        products.mkdir()
        for name in names:
            source = executables[name]
            shutil.copy2(source, products / name)
            bundle = source.with_name(source.name + '.dSYM')
            if not bundle.is_dir():
                raise RuntimeError('Release build omitted debug symbols: ' + name)
            debug_info = checked(['xcrun', 'dwarfdump', '--debug-info', '--recurse-depth=0', str(bundle)])
            if 'DW_TAG_compile_unit' not in debug_info:
                raise RuntimeError('Release debug-symbol bundle contains no compilation units: ' + name)
            shutil.copytree(bundle, products / (name + '.dSYM'))
        arguments = ['python3', str(ROOT / 'Tools/DebugSymbols/package.py'),
                     '--build-directory', str(products), '--output-directory', str(evidence / 'container-dSYM'),
                     '--archive', str(evidence / 'container-dSYM.zip')]
        for name in names:
            arguments += ['--product', name]
        with (evidence / 'debug-symbols.log').open('w') as stream:
            subprocess.run(arguments, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=600)
        (evidence / 'debug-symbols.json').write_text(json.dumps({
            'archive': str(evidence / 'container-dSYM.zip'),
            'sha256': digest(evidence / 'container-dSYM.zip'),
            'products': names, 'source': revision,
        }, indent=2) + '\n')
        shutil.rmtree(products)
    init = guest['reference'] if lane == 'fork' else STOCK_INIT
    builder_image = builder['reference'] if lane == 'fork' else BUILDERS['stock']
    kernel_sha = reset_state(lane, init, builder_image)
    state = STATE / lane
    metadata = {'lane': lane, 'workspace': str(workspace), 'install': str(install),
                'state': str(state), 'binaries': fingerprints, 'kernel_sha256': kernel_sha,
                'init_image': init, 'builder_image': builder_image, 'workload_image': ALPINE,
                'cli_version': checked([str(install / 'bin/container'), '--version'],
                                       env=dict(env, LLVM_PROFILE_FILE=profile_file) if profile_file else env),
                'package_lock_sha256': digest(workspace / 'Package.resolved')}
    if lane == 'fork':
        metadata['init_archive_sha256'] = guest['archive_sha256']
        metadata['guest_artifact_identity'] = guest['identity']
        metadata['builder_archive_sha256'] = builder['archive_sha256']
        metadata['builder_artifact_identity'] = builder['identity']
    if revision[:7] not in metadata['cli_version']:
        raise RuntimeError('Built CLI source revision does not match the selected source')
    (evidence / f'{lane}-fingerprint.json').write_text(json.dumps(metadata, indent=2) + '\n')


def prepare_assets(evidence: Path) -> None:
    assets = INSTALLS / 'assets'
    assets.mkdir(parents=True, exist_ok=True)
    kernel_tar = assets / 'kernel.tar.zst'
    if not kernel_tar.exists():
        checked(['curl', '--fail', '--location', '--output', str(kernel_tar),
                 'https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst'],
                timeout=600)
    if digest(kernel_tar) != KERNEL_SHA:
        raise RuntimeError('Kernel archive checksum mismatch')
    checked(['tar', '-xf', str(kernel_tar), '-C', str(assets), KERNEL_MEMBER])
    # crane OCI output is a directory; the native image loader takes a tar.
    layout = assets / 'alpine.oci.tar'
    if not layout.exists():
        checked(['crane', 'pull', '--format=oci', '--annotate-ref', ALPINE, str(layout)], timeout=300)
    archive_path = assets / 'alpine.tar'
    with tarfile.open(archive_path, 'w') as archive_file:
        for name in ('oci-layout', 'index.json', 'blobs'):
            archive_file.add(layout / name, arcname=name)
    guest = verified_guest(evidence / 'guest-artifact.json')
    (evidence / 'assets.json').write_text(json.dumps({
        'kernel_archive_sha256': KERNEL_SHA, 'alpine_archive_sha256': digest(archive_path),
        'alpine_reference': ALPINE, 'fork_init_archive_sha256': guest['archive_sha256']}, indent=2) + '\n')


def stock_lockfile(fork_lock: dict, native_lock: dict) -> dict:
    """Resolve the exact stock overlay before deciding whether its cache is reusable."""
    pins = {pin['identity']: pin for pin in fork_lock['pins']}
    pins.update({pin['identity']: pin for pin in native_lock['pins']})
    return dict(native_lock, pins=[pins[identity] for identity in sorted(pins)])


def stock_workspace_key(root: Path, lockfile: dict) -> str:
    inputs = [root / name for name in ('MODULE.bazel', 'MODULE.bazel.lock', '.bazelrc', '.bazelversion')]
    inputs += sorted(path for path in (root / 'Tools/bazel').iterdir()
                     if path.suffix in {'.bzl', '.patch', '.sh'} or path.name == 'BUILD.bazel')
    effective = {'lockfile': lockfile,
                 'files': {str(path.relative_to(root)): digest(path) for path in inputs}}
    return hashlib.sha256(json.dumps(effective, sort_keys=True).encode()).hexdigest()[:12]


def build_inputs(root: Path = ROOT) -> dict[str, str]:
    """Bind prepared products to their manifests, compiler rules and helper source."""
    paths = [root / name for name in ('Package.swift', 'Package.resolved', 'MODULE.bazel',
                                     'MODULE.bazel.lock', 'BUILD.bazel', '.bazelrc', '.bazelversion')]
    paths += [p for p in (root / 'Tools/bazel').iterdir()
              if p.suffix in {'.bzl', '.patch'} or p.name == 'semantic_metadata.py']
    paths += [p for p in (root / 'Tools/ContainerSemanticHelper').rglob('*')
              if p.is_file() and p.suffix in {'.go', '.mod', '.sum', '.py', '.bazel'}]
    return {str(p.relative_to(root)): digest(p) for p in sorted(paths)}


def prepare_all(evidence: Path, context: str = 'colima') -> None:
    enrollment = Path.home() / 'Library/Application Support/ContainerFamily/retained/workflow/ssd-volume.uuid'
    disk = plistlib.loads(checked(['/usr/sbin/diskutil', 'info', '-plist', '/Volumes/SSD']).encode())
    if disk.get('VolumeUUID') != enrollment.read_text().strip() or disk.get('MountPoint') != '/Volumes/SSD' or disk.get('Internal'):
        raise RuntimeError('The enrolled external SSD is unavailable')
    if digest(BAZEL) != BAZEL_SHA:
        raise RuntimeError('Pinned Bazel checksum mismatch')
    identities = checked(['security', 'find-identity', '-v', '-p', 'codesigning'])
    if IDENTITY not in identities:
        raise RuntimeError('The stable Steve Clarke signing identity is unavailable')
    if not (evidence / 'guest-artifact.json').exists():
        from guest_artifact import build
        guest_evidence = evidence / 'guest-build'
        guest_evidence.mkdir()
        build(Path(PAIRS['containerization']['repo']), guest_evidence)
        shutil.copy2(guest_evidence / 'guest-artifact.json', evidence / 'guest-artifact.json')
    if not (evidence / 'builder-artifact.json').exists():
        from builder_artifact import build as build_builder
        builder_evidence = evidence / 'builder-build'
        build_builder(builder_evidence, context, Path(PAIRS['container-builder-shim']['repo']))
        shutil.copy2(builder_evidence / 'builder-artifact.json', evidence / 'builder-artifact.json')
    prepare_assets(evidence)
    # Fork-only revisions replaced by stock pins must not invalidate Apple's build.
    native = json.loads(checked(['git', '-C', PAIRS['container']['repo'], 'show',
                                 PAIRS['container']['stock'] + ':Package.resolved']))
    lock = stock_lockfile(json.loads((ROOT / 'Package.resolved').read_text()), native)
    key = stock_workspace_key(ROOT, lock)
    scratch = STORAGE / 'runtime-comparison' / f'{PAIRS["container"]["stock"][:12]}-{key}'
    own(scratch, 'paired')
    stock = prepare('container', 'stock', scratch)
    (stock / 'Package.resolved').write_text(json.dumps(lock, indent=2) + '\n')
    (evidence / 'source-inputs.json').write_text(json.dumps({
        'stock': PAIRS['container']['stock'], 'stock_native_pins': native['pins'],
        'fork': checked(['git', 'rev-parse', 'HEAD'], cwd=ROOT),
        'fork_pins': json.loads((ROOT / 'Package.resolved').read_text())['pins'],
        'build_inputs': build_inputs(),
        'source_sha256': {lane: {str(p.relative_to(workspace)): digest(p)
                               for p in sorted((workspace / 'Sources').rglob('*')) if p.is_file()}
                          for lane, workspace in [('fork', ROOT), ('stock', stock)]},
    }, indent=2) + '\n')
    for lane, workspace in [('fork', ROOT), ('stock', stock)]:
        output_root = STORAGE / ('output' if lane == 'fork' else 'runtime-output')
        revision = checked(['git', 'rev-parse', 'HEAD'], cwd=ROOT) if lane == 'fork' else PAIRS['container']['stock']
        target = '//:container' if lane == 'fork' else '//:component'
        arguments = [str(BAZEL), '--output_user_root=' + str(output_root), 'build', target,
                     '--config=release', '--repo_env=GIT_COMMIT=' + revision,
                     '--repository_cache=' + str(STORAGE / 'repositories'),
                     '--build_event_json_file=' + str(evidence / f'{lane}-release.events.json')]
        print(f'Building optimized {lane}; see {evidence / (lane + "-release-build.log")}', flush=True)
        with (evidence / f'{lane}-release-build.log').open('w') as log:
            subprocess.run(arguments, cwd=workspace, env=dict(build_environment(), GIT_COMMIT=revision),
                           stdout=log, stderr=subprocess.STDOUT, timeout=1800, check=True)
        stage(lane, workspace, output_root, evidence)


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['stock', 'fork'])
    parser.add_argument('--prepare', action='store_true', help='Build optimized stacks, sign and stage before measuring')
    parser.add_argument('--prepared', type=Path, help='Reuse a verified installation from earlier qualification evidence')
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--output-root', type=Path)
    parser.add_argument('--guest-artifact', type=Path, help='Verified receipt for the pinned source-built guest')
    parser.add_argument('--builder-artifact', type=Path, help='Verified receipt for the pinned source-built builder')
    parser.add_argument('--context', default='colima', help='Running Docker context for builder qualification')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if args.trials < 1:
        parser.error('--trials must be positive')
    if args.stage and (not args.workspace or not args.output_root):
        parser.error('--stage requires --workspace and --output-root')
    if args.prepared and (args.prepare or args.stage):
        parser.error('--prepared cannot be combined with --prepare or --stage')
    args.evidence.mkdir(parents=True, exist_ok=True)
    if args.prepare and any(args.evidence.iterdir()):
        parser.error('--prepare requires a new evidence directory')
    if (args.evidence / 'operations.json').exists():
        parser.error('Evidence already contains a run; choose a new directory to preserve failures')
    if args.guest_artifact:
        guest = verified_guest(args.guest_artifact)
        (args.evidence / 'guest-artifact.json').write_text(json.dumps(guest, indent=2) + '\n')
    if args.builder_artifact:
        builder = verified_builder(args.builder_artifact)
        (args.evidence / 'builder-artifact.json').write_text(json.dumps(builder, indent=2) + '\n')
    INSTALLS.mkdir(parents=True, exist_ok=True)
    with (INSTALLS / 'benchmark.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            if args.prepared:
                from runtime_integration import verify_prepared
                verify_prepared(args.prepared)
                for name in ('source-inputs.json', 'fork-fingerprint.json', 'stock-fingerprint.json',
                             'guest-artifact.json', 'builder-artifact.json', 'assets.json'):
                    shutil.copy2(args.prepared / name, args.evidence / name)
            if args.prepare:
                prepare_all(args.evidence, args.context)
            if args.stage:
                stage(args.stage, args.workspace, args.output_root, args.evidence)
            else:
                benchmark(args.evidence, args.trials, reset=args.prepared is not None)
            if args.prepared:
                verify_prepared(args.prepared)
        except BaseException as error:
            (args.evidence / 'fatal.json').write_text(json.dumps({'error': str(error)}, indent=2) + '\n')
            raise


if __name__ == '__main__':
    main()
