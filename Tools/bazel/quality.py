#!/usr/bin/env python3
"""Analyze an immutable source checkpoint with source-verified coverage and Sonar policy."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request

from coverage import source_files
from fork_benchmark import ROOT, STORAGE, Runner, digest, install_signal_handlers

PROJECT = 'stephenlclarke_container'


def api(endpoint: str, parameters: dict) -> dict:
    token = os.environ.get('SONAR_TOKEN') or os.environ.get('SONAR_TOKEN_PERSONAL')
    if not token:
        raise RuntimeError('Sonar token is not configured')
    authorization = base64.b64encode((token + ':').encode()).decode()
    request = urllib.request.Request('https://sonarcloud.io/api/' + endpoint + '?' + urllib.parse.urlencode(parameters),
                                     headers={'Authorization': 'Basic ' + authorization})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def validate_policy(settings: dict) -> None:
    values = {row['key']: row.get('value') for row in settings['settings']}
    if any(values.get(key) != 'previous_version' for key in ('sonar.leak.period', 'sonar.leak.period.type')):
        raise RuntimeError('Sonar project new-code policy is not Previous version')


def checkpoint() -> str:
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        raise RuntimeError('Authoritative quality analysis requires a clean, committed checkpoint')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise RuntimeError('Quality analysis requires an exact Git SHA')
    return revision


def run(evidence: Path, coverage: Path) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    result = {'passed': False, 'failures': []}
    try:
        revision = checkpoint()
        result['revision'] = revision
        report = json.loads((coverage / 'coverage.json').read_text())
        if not report['passed'] or report['source_files'] != source_files():
            raise RuntimeError('Coverage does not match the current source tree')
        xml = coverage / 'coverage.xml'
        if digest(xml) != report['reports']['coverage.xml']:
            raise RuntimeError('Coverage report changed after collection')
        policy = api('settings/values', {'component': PROJECT, 'keys': 'sonar.leak.period,sonar.leak.period.type'})
        (evidence / 'new-code-policy.json').write_text(json.dumps(policy, indent=2) + '\n')
        validate_policy(policy)
        branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
        if not branch:
            raise RuntimeError('Quality analysis requires a named source branch')
        runner = Runner(evidence, STORAGE)
        runner.env = dict(os.environ, SONAR_TOKEN=os.environ.get('SONAR_TOKEN') or os.environ['SONAR_TOKEN_PERSONAL'])
        row = runner.run('quality', 'fork', 'sonar', 0, ['sonar-scanner',
                         '-Dsonar.projectVersion=' + revision, '-Dsonar.scm.revision=' + revision,
                         '-Dsonar.branch.name=' + branch, '-Dsonar.coverageReportPaths=' + str(xml),
                         '-Dsonar.working.directory=' + str(evidence / 'scanner'),
                         '-Dsonar.qualitygate.wait=true', '-Dsonar.qualitygate.timeout=600'], ROOT, 1800)
        task_file = evidence / 'scanner/report-task.txt'
        if task_file.exists():
            task = dict(line.split('=', 1) for line in task_file.read_text().splitlines() if '=' in line)
            details = api('ce/task', {'id': task['ceTaskId']})
            (evidence / 'analysis-task.json').write_text(json.dumps(details, indent=2) + '\n')
            analysis = details['task'].get('analysisId')
            if analysis:
                gate = api('qualitygates/project_status', {'analysisId': analysis})
                (evidence / 'quality-gate.json').write_text(json.dumps(gate, indent=2) + '\n')
                result.update(analysis_id=analysis, dashboard=task.get('dashboardUrl'), gate=gate['projectStatus']['status'])
        if row['status'] or result.get('gate') != 'OK':
            raise RuntimeError('Sonar analysis or quality gate failed; see retained scanner output and gate conditions')
        if checkpoint() != revision:
            raise RuntimeError('Source changed during authoritative analysis')
        result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'quality.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--coverage', type=Path, required=True)
    args = parser.parse_args()
    run(args.evidence, args.coverage)


if __name__ == '__main__':
    main()
