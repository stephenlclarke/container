#!/usr/bin/env python3
"""Collect real Bazel line coverage, bind it to source contents and export Sonar XML."""

import argparse
import json
from pathlib import Path
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET

from fork_benchmark import ROOT, STORAGE, Runner, digest, install_signal_handlers
from release_artifact import run_command


def source_files() -> dict[str, str]:
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted((ROOT / 'Sources').rglob('*')) if p.is_file()}


def normalize_lcov(text: str) -> str:
    records = []
    for block in text.split('end_of_record'):
        lines = block.strip().splitlines()
        source = next((line[3:] for line in lines if line.startswith('SF:')), None)
        if source is None:
            continue
        relative = source.removeprefix('./').removeprefix('external/+dependencies+swiftpkg_container/')
        relative = relative.removeprefix(str(ROOT) + '/')
        if not relative.startswith('Sources/'):
            continue
        if '..' in Path(relative).parts:
            raise RuntimeError('Coverage path escapes the source tree')
        records.append('\n'.join('SF:' + relative if line.startswith('SF:') else line for line in lines)
                       + '\nend_of_record\n')
    normalized = ''.join(records)
    if not re.search(r'^DA:[1-9][0-9]*,[1-9][0-9]*(?:,.*)?$', normalized, re.M):
        raise RuntimeError('Coverage contains no covered executable source lines')
    return normalized


def run(evidence: Path) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, STORAGE)
    result = {'passed': False, 'failures': [], 'source_files': source_files()}
    try:
        log = run_command(runner, 'unit-coverage', [str(ROOT / 'Tools/bazel/run.sh'), 'coverage', '//:container-tests',
                          '--instrumentation_filter=.*swiftpkg_container//', '--combined_report=lcov'], 1800)
        match = re.search(r'LCOV coverage report is located at (.+)$', log.read_text(), re.M)
        if not match:
            raise RuntimeError('Bazel omitted the combined coverage report')
        raw = Path(match[1])
        shutil.copyfile(raw, evidence / 'raw.lcov')
        lcov = evidence / 'coverage.lcov'
        lcov.write_text(normalize_lcov(raw.read_text()))
        xml = evidence / 'coverage.xml'
        # The original converter deliberately confines input/output to the repo.
        # Use private scratch there, then retain the exported report off-checkout.
        (ROOT / '.build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='bazel-coverage-', dir=ROOT / '.build') as directory:
            temporary = Path(directory)
            shutil.copyfile(lcov, temporary / 'coverage.lcov')
            run_command(runner, 'sonar-coverage', ['python3', 'scripts/lcov-to-sonarqube-generic.py',
                        str(temporary / 'coverage.lcov'), str(temporary / 'coverage.xml')])
            shutil.copyfile(temporary / 'coverage.xml', xml)
        files = list(ET.parse(xml).getroot())
        lines = [line for file in files if not file.get('path').endswith(('.pb.swift', '.grpc.swift')) for line in file]
        covered = sum(line.get('covered') == 'true' for line in lines)
        if not lines or not covered:
            raise RuntimeError('Converted coverage report is empty')
        if source_files() != result['source_files']:
            raise RuntimeError('Sources changed while collecting coverage')
        result.update(passed=True, covered_lines=covered, executable_lines=len(lines),
                      line_percent=round(100 * covered / len(lines), 2),
                      reports={p.name: digest(p) for p in (lcov, xml)},
                      scope='Container host unit tests; Linux, runtime and service coverage are separate evidence')
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'coverage.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    run(parser.parse_args().evidence)


if __name__ == '__main__':
    main()
