#!/usr/bin/env python3
"""Trace the Bazel Swift build and retain CodeQL results for an exact clean commit."""

import argparse
import json
from pathlib import Path
import subprocess

from fork_benchmark import BAZEL, ROOT, STORAGE, Runner, digest, install_signal_handlers
from quality import checkpoint

CLI = STORAGE / 'toolchains/codeql-2.27.1/codeql/codeql'
ARCHIVE_SHA = '412c600764a7835f9548af120d0bdadea1040c6f68b8f6bf04ec72a664891f63'
QUERY = 'codeql/swift-queries@1.3.11:codeql-suites/swift-code-scanning.qls'


def run(evidence: Path) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, STORAGE)
    result = {'passed': False, 'failures': []}
    try:
        revision = checkpoint()
        archive = CLI.parent.parent / 'codeql-osx64.zip'
        if not CLI.is_file() or not archive.is_file() or digest(archive) != ARCHIVE_SHA:
            raise RuntimeError('Install the verified CodeQL 2.27.1 macOS archive before qualification')
        version = json.loads(subprocess.check_output([str(CLI), 'version', '--format=json'], text=True, timeout=30))
        if version['version'] != '2.27.1':
            raise RuntimeError('Unexpected CodeQL version')
        result.update(source=revision, cli=version, archive_sha256=ARCHIVE_SHA, queries=QUERY)
        database = evidence / 'database'
        row = runner.run('codeql', 'fork', 'initialize', 0,
                         [str(CLI), 'database', 'init', str(database), '--language=swift',
                          '--source-root=' + str(ROOT), '--begin-tracing'], ROOT, 120)
        if row['status']:
            raise RuntimeError('CodeQL database initialization failed')
        tracing = json.loads((database / 'temp/tracingEnvironment/start-tracing.json').read_text())
        # The macOS tracer cannot relocate/re-sign Bazel's self-extracting
        # launcher. Indirect tracing instruments its child compiler actions,
        # with an explicit environment across Bazel's action boundary.
        command = [str(BAZEL), '--batch', '--output_user_root=' + str(STORAGE / 'codeql-output'),
                   'build', '//:container', '--spawn_strategy=local', '--strategy=SwiftCompile=local',
                   '--nouse_action_cache', '--noremote_accept_cached', '--disk_cache=',
                   '--repository_cache=' + str(STORAGE / 'repositories'),
                   '--action_env=DEVELOPER_DIR', *['--action_env=' + key for key in sorted(tracing)]]
        original_environment = runner.env
        runner.env = dict(original_environment, **tracing)
        runner.env['DEVELOPER_DIR'] = original_environment.get('DEVELOPER_DIR') or subprocess.check_output(
            ['xcode-select', '-p'], text=True, timeout=30).strip()
        try:
            row = runner.run('codeql', 'fork', 'extract', 0, command, ROOT, 3600)
        finally:
            runner.env = original_environment
        if row['status']:
            raise RuntimeError('CodeQL Swift extraction failed')
        row = runner.run('codeql', 'fork', 'finalize', 0,
                         [str(CLI), 'database', 'finalize', str(database), '--threads=6', '--ram=8192'], ROOT, 900)
        if row['status']:
            raise RuntimeError('CodeQL database finalization failed or captured no Swift source')
        row = runner.run('codeql', 'fork', 'analyze', 0,
                         [str(CLI), 'database', 'analyze', str(evidence / 'database'), QUERY,
                          '--download', '--format=sarif-latest', '--output=' + str(evidence / 'results.sarif'),
                          '--threads=6', '--ram=8192'], ROOT, 1800)
        if row['status']:
            raise RuntimeError('CodeQL Swift analysis failed')
        sarif = json.loads((evidence / 'results.sarif').read_text())
        runs = sarif.get('runs', [])
        if not runs or not all(run.get('invocations') and all(invocation.get('executionSuccessful') for invocation in run['invocations']) for run in runs):
            raise RuntimeError('CodeQL omitted a successful analysis invocation')
        findings = [finding for run in runs for finding in run.get('results', [])]
        result.update(findings=len(findings), sarif_sha256=digest(evidence / 'results.sarif'))
        if findings:
            raise RuntimeError('CodeQL findings require review; see retained SARIF')
        if checkpoint() != revision:
            raise RuntimeError('Source changed during CodeQL analysis')
        result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'codeql.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    run(parser.parse_args().evidence)
