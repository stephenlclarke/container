#!/usr/bin/env python3
"""Combine independently qualified unit and full integration line coverage."""

import argparse
import json
from pathlib import Path

from coverage import export_reports, merge_lcov, source_files
from fork_benchmark import STORAGE, Runner, digest, install_signal_handlers


def qualified_report(directory: Path, sources: dict[str, str], integration: bool = False) -> str:
    record = json.loads((directory / 'coverage.json').read_text())
    if not record.get('passed') or record.get('source_files') != sources:
        raise RuntimeError('Coverage did not pass for the current sources: ' + str(directory))
    if integration and (not record.get('full_suite') or not record.get('restored')):
        raise RuntimeError('Combined coverage requires the full integration suite and restored runtime')
    for name, sha in record['reports'].items():
        if digest(directory / name) != sha:
            raise RuntimeError('Coverage report changed: ' + str(directory / name))
    if not record['reports'].get('coverage.lcov'):
        raise RuntimeError('Coverage LCOV provenance is missing')
    return (directory / 'coverage.lcov').read_text()


def run(evidence: Path, unit: Path, integration: Path) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, STORAGE)
    sources = source_files()
    result = dict(passed=False, failures=[], source_files=sources)
    try:
        text = merge_lcov([qualified_report(unit, sources), qualified_report(integration, sources, True)])
        result.update(export_reports(runner, evidence, text))
        if source_files() != sources:
            raise RuntimeError('Sources changed while combining coverage')
        result.update(passed=True, kind='unit-and-full-integration',
                      inputs={str(p): digest(p / 'coverage.json') for p in (unit, integration)},
                      scope='Union of container host unit and full CLI integration/runtime executable lines')
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'coverage.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--unit', type=Path, required=True)
    parser.add_argument('--integration', type=Path, required=True)
    args = parser.parse_args()
    run(args.evidence, args.unit, args.integration)


if __name__ == '__main__':
    main()
