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
    reviewed = {(row['component'], row['fixture']) for row in differences}
    invalid_timings = [row for row in matrix if not row['passed'] and
                       ((row['component'], row['fixture']) not in reviewed or row['fork'] >= 10 * row['stock'])]
    go_path = evidence / 'go-matrix.json'
    if go_path.exists():
        invalid_timings += [row for row in json.loads(go_path.read_text()) if not row['passed']]
    result = {'completed': bool(matrix) and not unexpected and not invalid_timings,
              'compatible': not differences and not unexpected,
              'expected_differences': differences, 'unexpected_failures': unexpected,
              'invalid_timings': invalid_timings,
              'interpretation': 'Reviewed name-length and rejected-certificate alert differences remain failed compatibility assertions. Their timings are not qualified performance comparisons.'}
    (evidence / 'comparison-review.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
