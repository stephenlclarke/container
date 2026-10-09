#!/usr/bin/env python3
"""Collect real Bazel line coverage, bind it to source contents and export Sonar XML."""

import argparse
from html import escape
import json
from pathlib import Path
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET

from fork_benchmark import ROOT, STORAGE, Runner, digest, install_signal_handlers

def run_command(runner: Runner, name: str, args: list[str], timeout: int = 300) -> Path:
    row = runner.run('coverage', 'fork', name, 0, args, ROOT, timeout)
    if row['status']:
        raise RuntimeError(name + ' failed; see ' + row['log'])
    return Path(row['log'])


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


def line_counts(text: str) -> dict[str, dict[int, int]]:
    """Merge line counters, including uncovered lines, without double-counting files."""
    result: dict[str, dict[int, int]] = {}
    for block in normalize_lcov(text).split('end_of_record'):
        lines = block.strip().splitlines()
        source = next((line[3:] for line in lines if line.startswith('SF:')), None)
        if source is None:
            continue
        counts = result.setdefault(source, {})
        for line in lines:
            if line.startswith('DA:'):
                number, hits, *_ = line[3:].split(',')
                number, hits = int(number), int(hits)
                if number < 1 or hits < 0:
                    raise RuntimeError('Invalid coverage line counter')
                counts[number] = counts.get(number, 0) + hits
    return result


def merge_lcov(reports: list[str]) -> str:
    if not reports:
        raise RuntimeError('No coverage reports to combine')
    # Each input must be independently nonempty; an empty tier is not coverage.
    counts: dict[str, dict[int, int]] = {}
    for report in reports:
        for source, lines in line_counts(report).items():
            merged = counts.setdefault(source, {})
            for number, hits in lines.items():
                merged[number] = merged.get(number, 0) + hits
    records = []
    for source, lines in sorted(counts.items()):
        records += ['SF:' + source, *[f'DA:{number},{hits}' for number, hits in sorted(lines.items())],
                    'LF:' + str(len(lines)), 'LH:' + str(sum(hits > 0 for hits in lines.values())), 'end_of_record']
    return '\n'.join(records) + '\n'


def export_reports(runner: Runner, evidence: Path, text: str) -> dict:
    """Retain source-relative LCOV, Sonar XML, a line summary and browsable source."""
    lcov = evidence / 'coverage.lcov'
    lcov.write_text(merge_lcov([text]))
    xml = evidence / 'coverage.xml'
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
    summary = dict(covered_lines=covered, executable_lines=len(lines), line_percent=round(100 * covered / len(lines), 2))
    (evidence / 'coverage-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (evidence / 'coverage-percent.txt').write_text(f'Lines: {summary["line_percent"]}% ({covered}/{len(lines)})\n')
    html = evidence / 'html'
    html.mkdir()
    links = []
    for index, (source, counts) in enumerate(sorted(line_counts(lcov.read_text()).items())):
        content = (ROOT / source).read_text().splitlines()
        if counts and max(counts) > len(content):
            raise RuntimeError('Coverage line exceeds source length: ' + source)
        filename = str(index) + '.html'
        links.append(f'<li><a href="{filename}">{escape(source)}</a></li>')
        rows = []
        for number, line in enumerate(content, 1):
            hits = counts.get(number)
            color = '#e4f4e4' if hits else '#f9dede' if hits == 0 else 'white'
            rows.append(f'<tr style="background:{color}"><td>{number}</td><td>{hits if hits is not None else ""}</td><td><pre>{escape(line)}</pre></td></tr>')
        (html / filename).write_text('<!doctype html><meta charset="utf-8"><style>pre{margin:0}td{vertical-align:top;padding:0 6px}</style><title>' + escape(source)
                                    + '</title><h1>' + escape(source) + '</h1><table>' + ''.join(rows) + '</table>')
    (html / 'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Line coverage</title>'
                                   + '<h1>Line coverage</h1><p>' + str(summary['line_percent']) + '%</p><ul>' + ''.join(links) + '</ul>')
    summary['reports'] = {p.name: digest(p) for p in (lcov, xml)}
    return summary


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
        result.update(export_reports(runner, evidence, raw.read_text()))
        if source_files() != result['source_files']:
            raise RuntimeError('Sources changed while collecting coverage')
        result.update(passed=True, scope='Container host unit line coverage; integration is reported separately')
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
