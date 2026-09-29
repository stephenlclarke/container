"""Keep intentional upstream contract differences distinct from speed and build failures."""

import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

DIFFERENCES = {
    ('container', 'ContainerResourceTests'): {
        'nameValidRejectsNamesLongerThan63Characters()': 'Expectation failed: !ManagedContainer.nameValid(tooLongName)',
    },
    ('swift-nio-ssl', 'NIOSSLTests'): {
        'testMutualValidationWithCertVerificationOptionalError_PeerCertNotTrusted': 'SSLV3_ALERT_BAD_CERTIFICATE',
        'testServerCannotValidateClientPreTLS13': 'SSLV3_ALERT_BAD_CERTIFICATE',
        'testServerCannotValidateClientPostTLS13': 'SSLV3_ALERT_BAD_CERTIFICATE',
    },
}


def known_difference(row: dict) -> bool:
    expected = DIFFERENCES.get((row['component'], row['fixture']))
    if row['lane'] != 'fork' or row['status'] != 3 or not expected or not row.get('events'):
        return False
    if not row.get('log') or re.search(r'Fatal error:|Abort trap|Signal \d+|Segmentation fault|crashed|timed out', Path(row['log']).read_text(), re.I):
        return False
    reports = Path(row['events']).with_suffix('.tests')
    index = reports / 'index.json'
    if not index.exists() or [item['status'] for item in json.loads(index.read_text())] != ['FAILED']:
        return False
    failures = {}
    for report in reports.rglob('test.xml'):
        for case in ET.parse(report).iter('testcase'):
            if case.find('error') is not None:
                return False
            for failure in case.findall('failure'):
                if case.get('name') in failures:
                    return False
                failures[case.get('name')] = failure.get('message', '') + (failure.text or '')
    return failures.keys() == expected.keys() and all(message in failures[name] for name, message in expected.items())


def review(evidence: Path) -> dict:
    rows = json.loads((evidence / 'results.json').read_text())
    matrix = json.loads((evidence / 'matrix.json').read_text())
    differences = [row for row in rows if row['status'] and known_difference(row)]
    unexpected = [row for row in rows if row['status'] and row not in differences]
    historical = []
    superseded = []
    historical_path = evidence / 'historical-differences.json'
    if historical_path.exists():
        from benchmark_reference import fetch
        from component_reference import retained_rows
        scope = json.loads((evidence / 'metadata.json').read_text())
        reference = fetch()
        _, historical = retained_rows(reference, scope['measured_components'])
        superseded = [dict(row, historical=True) for row in reference['components']['knownCompatibilityDifferences']
                      if row['component'] in scope['measured_components']]
        if json.loads(historical_path.read_text()) != historical:
            raise RuntimeError('Historical compatibility disposition differs from the pinned archive')
    reviewed = {(row['component'], row['fixture']) for row in differences + historical}
    invalid_timings = [row for row in matrix if not row['passed'] and
                       ((row['component'], row['fixture']) not in reviewed or row['fork'] >= 10 * row['stock'])]
    go_path = evidence / 'go-matrix.json'
    if go_path.exists():
        invalid_timings += [row for row in json.loads(go_path.read_text()) if not row['passed']]
    metadata = evidence / 'metadata.json'
    scope = json.loads(metadata.read_text()) if metadata.exists() else {}
    phase = scope.get('phase', 'all')
    compatibility_measured = phase not in {'tls', 'recompile'}
    if scope.get('historical_reference') and not scope.get('measured_components'):
        compatibility_measured = False
    result = {'phase': phase, 'components': scope.get('components'),
              'compatibility_measured': compatibility_measured,
              'completed': bool(matrix) and not unexpected and not invalid_timings,
              'compatible': (not differences and not historical and not unexpected) if compatibility_measured else None,
              'expected_differences': differences, 'unexpected_failures': unexpected,
              'historical_expected_differences': historical,
              'superseded_historical_differences': superseded,
              'freshly_measured_components': scope.get('measured_components', scope.get('components')),
              'invalid_timings': invalid_timings,
              'interpretation': 'Reviewed name-length and rejected-certificate alert differences remain failed compatibility assertions. Their timings are not qualified performance comparisons.'}
    if not compatibility_measured:
        result['interpretation'] = 'Workload-only measurement; no compatibility suite was run and no whole-component compatibility claim is made.'
    (evidence / 'comparison-review.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
