#!/usr/bin/env python3
"""Exercise the pinned guest's Linux-only tests in a bounded, disposable container."""

import argparse
import fcntl
import json
from pathlib import Path
import re
import shutil
import subprocess
import uuid

from fork_benchmark import ROOT, STORAGE, Runner, digest, output, install_signal_handlers
from guest_artifact import snapshot

IMAGE = 'container-only-linux-tests:swift63'
LAYERS = {
    'guest-core': ('/source', 'VminitdCoreTests|ContainerizationNetlinkTests'),
    'vmexec': ('/source/vminitd', 'vmexecTests'),
}


def test_arguments(context: str, image: str, name: str, source: Path, build: Path,
                   layer: str, revision: str) -> list[str]:
    package, selection = LAYERS[layer]
    return ['docker', '--context', context, 'run', '--rm', '--name', name,
            '--label', 'io.container-only.owner=' + name, '--platform', 'linux/arm64',
            '--cpus', '4', '--memory', '6g', '--pids-limit', '2048',
            '--read-only', '--tmpfs', '/tmp:exec,size=2g',
            '--mount', f'type=bind,src={source},dst=/source,readonly',
            '--mount', f'type=bind,src={build},dst=/build',
            '--env', 'HOME=/build/home', '--env', 'CI=1', '--env', 'GIT_COMMIT=' + revision,
            image, 'swift', 'test', '--package-path', package, '--scratch-path', '/build/' + layer,
            '--cache-path', '/build/cache', '--disable-automatic-resolution', '--jobs', '4',
            '--enable-code-coverage', '--filter', selection]


def cleanup(context: str, name: str) -> None:
    docker = ['docker', '--context', context]
    result = subprocess.run(docker + ['inspect', name], capture_output=True, text=True, timeout=20)
    if result.returncode:
        # Distinguish an absent container from a lost daemon, so cleanup cannot
        # report success while an unobservable workload is still running.
        subprocess.run(docker + ['info', '--format', '{{.ID}}'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20)
        return
    container = json.loads(result.stdout)[0]
    if container['Config']['Labels'].get('io.container-only.owner') != name:
        raise RuntimeError('Refusing cleanup of a container without the matching ownership label')
    subprocess.run(docker + ['rm', '--force', container['Id']], check=True,
                   stdout=subprocess.DEVNULL, timeout=30)


def run(evidence: Path, context: str, repository: Path, layers: list[str]) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    base = STORAGE / 'linux'
    base.mkdir(parents=True, exist_ok=True)
    (STORAGE / 'tmp').mkdir(parents=True, exist_ok=True)
    runner = Runner(evidence, base)
    results = {'schema': 1, 'passed': False, 'layers': layers, 'context': context}
    try:
        with (base / 'build.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            docker = ['docker', '--context', context]
            row = runner.run('linux', 'fork', 'image-build', 0,
                             docker + ['build', '--platform', 'linux/arm64', '--tag', IMAGE,
                                       '--file', str(Path(__file__).with_name('linux-test.Dockerfile')),
                                       str(Path(__file__).parent)], ROOT, timeout=1200)
            if row['status']:
                raise RuntimeError('Linux test image build failed: ' + row['log'])
            image = output(docker + ['image', 'inspect', '--format', '{{.Id}}', IMAGE])
            revision = next(p['state']['revision'] for p in json.loads((ROOT / 'Package.resolved').read_text())['pins']
                            if p['identity'] == 'containerization')
            source = base / 'source'
            source_identity = snapshot(repository, revision, source)
            build = base / 'build'
            (build / 'home').mkdir(parents=True, exist_ok=True)
            results.update(source=revision, source_files=source_identity['files'], image_id=image,
                           dockerfile_sha256=digest(Path(__file__).with_name('linux-test.Dockerfile')),
                           package_locks={name: digest(source / name) for name in
                                          ['Package.resolved', 'vminitd/Package.resolved']})
            for layer in layers:
                name = 'container-only-linux-' + uuid.uuid4().hex[:16]
                try:
                    row = runner.run('linux', 'fork', layer, 0,
                                     test_arguments(context, image, name, source, build, layer, revision),
                                     ROOT, timeout=1800)
                    if row['status']:
                        raise RuntimeError('Linux test layer failed: ' + row['log'])
                    completed = re.search(r'Test run with ([1-9][0-9]*) tests? .* passed', Path(row['log']).read_text())
                    if not completed:
                        raise RuntimeError('Linux test selection executed no verified tests: ' + row['log'])
                    row['executed_tests'] = int(completed[1])
                    coverage = build / layer / 'aarch64-unknown-linux-gnu/debug/codecov'
                    if coverage.is_dir():
                        shutil.copytree(coverage, evidence / (layer + '-coverage'))
                    else:
                        raise RuntimeError('Linux test layer produced no coverage evidence: ' + layer)
                finally:
                    cleanup(context, name)
            if snapshot(repository, revision, source) != source_identity:
                raise RuntimeError('Linux source snapshot changed during verification')
            results['passed'] = True
    except BaseException as error:
        results['error'] = str(error)
        raise
    finally:
        results['operations'] = runner.rows
        (evidence / 'linux-tests.json').write_text(json.dumps(results, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--context', default='colima')
    parser.add_argument('--repository', type=Path, default=Path.home() / 'github/containerization')
    parser.add_argument('--layer', choices=list(LAYERS), action='append')
    args = parser.parse_args()
    run(args.evidence, args.context, args.repository, args.layer or list(LAYERS))


if __name__ == '__main__':
    main()
