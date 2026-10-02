"""Require the hosted quality workflow for this exact local release candidate."""

import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
import time

from preflight import github_environment
from quality import REPOSITORY, analysis_context, checkpoint


DEFAULT_WAIT_SECONDS = 90 * 60


def current_context(revision: str) -> dict:
    context = analysis_context(revision)
    if context['kind'] == 'branch':
        remote = json.loads(subprocess.check_output([
            'gh', 'api', '--hostname', 'github.com', f'repos/{REPOSITORY}/git/ref/heads/main'],
            env=github_environment(), text=True, timeout=30))
        if remote['object']['sha'] != revision:
            raise RuntimeError('Local main does not match the current pushed main revision')
    return context


def select_run(runs: list[dict], context: dict) -> dict | None:
    expected_event = 'push' if context['kind'] == 'branch' else 'pull_request'
    matching = [run for run in runs if run.get('head_sha') == context['revision']
                and run.get('head_branch') == context['branch'] and run.get('event') == expected_event
                and run.get('repository', {}).get('full_name') == REPOSITORY
                and run.get('head_repository', {}).get('full_name') == REPOSITORY]
    if context['kind'] == 'pull_request':
        matching = [run for run in matching if any(
            str(pull.get('number')) == context['key']
            and pull.get('head', {}).get('sha') == context['revision']
            and pull.get('base', {}).get('sha') == context['base_revision']
            and pull.get('base', {}).get('ref') == context['base']
            for pull in run.get('pull_requests', []))]
    # Rerunning an older run retains its ID. Its latest attempt must outrank an
    # earlier successful result even when that result has a higher run ID.
    return max(matching, key=lambda run: (datetime.fromisoformat(run['run_started_at']),
                                         run['id'], run['run_attempt']), default=None)


def require_analysis_jobs(selected: dict, revision: str) -> dict[str, dict]:
    """A successful workflow with either analysis skipped is not quality evidence."""
    response = json.loads(subprocess.check_output([
        'gh', 'api', '--hostname', 'github.com',
        f'repos/{REPOSITORY}/actions/runs/{selected["id"]}/attempts/{selected["run_attempt"]}/jobs?per_page=100'],
        env=github_environment(), text=True, timeout=30))
    admitted = {}
    for name in ('Analyze Swift', 'Analyze CodeQL'):
        jobs = [job for job in response['jobs'] if job.get('name') == name]
        if (len(jobs) != 1 or jobs[0].get('head_sha') != revision
                or jobs[0].get('status') != 'completed' or jobs[0].get('conclusion') != 'success'):
            raise RuntimeError(f'Hosted {name} job must actually pass for this exact commit')
        admitted[name] = {key: jobs[0][key] for key in
                          ('id', 'head_sha', 'name', 'status', 'conclusion', 'html_url')}
    return admitted


def run(evidence: Path, timeout: float = DEFAULT_WAIT_SECONDS) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    result = {'passed': False, 'failures': []}
    try:
        revision = checkpoint()
        context = current_context(revision)
        result.update(source=revision, context=context, workflow='.github/workflows/sonar.yml')
        deadline = time.monotonic() + timeout
        while True:
            response = json.loads(subprocess.check_output([
                'gh', 'api', '--hostname', 'github.com',
                f'repos/{REPOSITORY}/actions/workflows/sonar.yml/runs?head_sha={revision}&per_page=100'],
                env=github_environment(), text=True, timeout=30))
            selected = select_run(response['workflow_runs'], context)
            if selected:
                result['run'] = {key: selected[key] for key in
                                 ('id', 'run_attempt', 'run_started_at', 'head_sha', 'status', 'conclusion', 'html_url')}
                if selected['status'] == 'completed':
                    if selected['conclusion'] != 'success':
                        raise RuntimeError('Hosted quality workflow did not pass: ' + selected['html_url'])
                    result['analysis_jobs'] = require_analysis_jobs(selected, revision)
                    break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('Hosted quality workflow is missing or still pending for this commit')
            time.sleep(min(30, remaining))
        if checkpoint() != revision or current_context(revision) != context:
            raise RuntimeError('Source or pull request changed while waiting for hosted quality')
        result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'quality.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    run(args.evidence)
