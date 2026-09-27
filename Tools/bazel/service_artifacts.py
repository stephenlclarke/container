#!/usr/bin/env python3
"""Run the original service race/reproducibility gates with owned container cleanup."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import uuid

from fork_benchmark import ROOT, STORAGE, Runner, digest, install_signal_handlers
from linux_tests import cleanup
from release_artifact import SERVICES, run_command

RETAINED = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/runtime-artifacts/services'


def load_service(name: str):
    path = ROOT / 'Tools' / SERVICES[name] / 'build.py'
    spec = importlib.util.spec_from_file_location('service_' + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def identity(name: str) -> dict:
    service = load_service(name)
    return {'source_sha256': service.production_source_digest(),
            'tests_sha256': service.test_source_digest(), 'platform': 'linux/arm64',
            'workflow_sha256': digest(Path(__file__))}


def build(evidence: Path, context: str) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    (STORAGE / 'services').mkdir(exist_ok=True)
    runner = Runner(evidence, STORAGE)
    runner.env['DOCKER_CONTEXT'] = context
    result = {'schema': 1, 'passed': False, 'assets': [], 'failures': []}
    try:
        with (STORAGE / 'services/build.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for name, directory in SERVICES.items():
                source_identity = identity(name)
                key = hashlib.sha256(json.dumps(source_identity, sort_keys=True).encode()).hexdigest()
                retained = RETAINED / name / key
                receipt = retained / 'artifact.json'
                tool = ROOT / 'Tools' / directory / 'build.py'
                archive = retained / ('container-' + name + '-service.oci.tar')
                manifest = retained / ('container-' + name + '-service.manifest.json')
                reused = receipt.exists()
                if reused:
                    record = json.loads(receipt.read_text())
                    if record['identity'] != source_identity:
                        raise RuntimeError('Service identity mismatch: ' + name)
                    for relative, expected in record['files'].items():
                        if digest(retained / relative) != expected:
                            raise RuntimeError('Retained service artifact/evidence changed: ' + name)
                else:
                    retained.mkdir(parents=True, exist_ok=True)
                    test_id = uuid.uuid4().hex
                    runner.env['CONTAINER_SERVICE_TEST_ID'] = test_id
                    runner.env['CONTAINER_SERVICE_TEST_EVIDENCE'] = str(retained / 'tests')
                    try:
                        log = run_command(runner, name + '-test-and-build',
                                          ['python3', str(tool), 'test', '--output-directory', str(retained)], 1800)
                        shutil.copyfile(log, retained / 'test-and-build.log')
                    finally:
                        cleanup(context, 'container-service-test-' + test_id)
                    coverage = retained / 'tests/coverage.out'
                    if not coverage.is_file() or len(coverage.read_text().splitlines()) < 2:
                        raise RuntimeError('Service tests omitted coverage: ' + name)
                    if identity(name) != source_identity:
                        raise RuntimeError('Service source changed during qualification: ' + name)
                    record = {'identity': source_identity, 'files': {
                        str(p.relative_to(retained)): digest(p) for p in sorted(retained.rglob('*')) if p.is_file()}}
                run_command(runner, name + '-verify', ['python3', str(tool), 'verify',
                            '--archive', str(archive), '--manifest', str(manifest)])
                receipt.write_text(json.dumps(record, indent=2) + '\n')
                result['assets'].append({'service': name, 'archive': str(archive), 'manifest': str(manifest),
                                         'identity': source_identity, 'reused': reused,
                                         'qualification': str(receipt), 'archive_sha256': digest(archive)})
            result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'service-artifacts.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--context', default='colima')
    args = parser.parse_args()
    build(args.evidence, args.context)


if __name__ == '__main__':
    main()
