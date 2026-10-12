#!/usr/bin/env python3
"""Run the original Swift/journald wire test using Bazel, with checked resource cleanup."""

import argparse
import json
from pathlib import Path
import subprocess
import uuid

from fork_benchmark import ROOT, STORAGE, Runner, install_signal_handlers
from runtime_integration import retain_layer_reports


def cleanup(context: str, token: str) -> None:
    docker = ['docker', '--context', context]
    owner = 'container-journald-integration-' + token
    resources = [('container', 'container-journald-' + part + token)
                 for part in ('service-', 'proxy-')]
    resources += [('volume', 'container-journald-' + part + token) for part in ('control-', 'state-')]
    resources += [('image', 'container-journald-service:integration-' + token)]
    for kind, name in resources:
        inspected = subprocess.run(docker + [kind, 'inspect', name], capture_output=True, text=True, timeout=20)
        if inspected.returncode:
            subprocess.run(docker + ['info', '--format', '{{.ID}}'], check=True,
                           capture_output=True, timeout=20)
            continue
        record = json.loads(inspected.stdout)[0]
        labels = record.get('Config', record).get('Labels', {}) or {}
        if labels.get('io.container-only.owner') != owner:
            raise RuntimeError('Refusing unrelated service integration cleanup: ' + kind)
        command = docker + [kind, 'rm'] + (['--force'] if kind == 'container' else []) + [name]
        subprocess.run(command, check=True, capture_output=True, timeout=30)


def run(evidence: Path, context: str) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    token = uuid.uuid4().hex
    runner = Runner(evidence, STORAGE)
    runner.env.update(DOCKER_CONTEXT=context, CONTAINER_SERVICE_TEST_ID=token)
    result = {'passed': False, 'failures': [], 'owner': 'container-journald-integration-' + token}
    try:
        row = runner.run('service', 'fork', 'journald-wire', 0,
                         ['python3', str(ROOT / 'Tools/ContainerJournaldService/build.py'),
                          'integration', '--test-driver', 'bazel'], ROOT, 900)
        if row['status']:
            raise RuntimeError('Swift/journald integration failed; see ' + row['log'])
        result['executed_tests'] = retain_layer_reports(Path(row['log']), evidence / 'reports')
        result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        try:
            cleanup(context, token)
            result['cleanup_complete'] = True
        except BaseException as error:
            result['passed'] = False
            result['failures'].append(str(error))
            raise
        finally:
            (evidence / 'service-integration.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--context', default='colima')
    args = parser.parse_args()
    run(args.evidence, args.context)


if __name__ == '__main__':
    main()
