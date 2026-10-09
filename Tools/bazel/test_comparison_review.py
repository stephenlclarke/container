"""Only the exact retained upstream assertions can receive a reviewed disposition."""

import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from comparison_review import DIFFERENCES, known_difference, review


class ComparisonReviewTests(unittest.TestCase):
    def test_workload_only_run_does_not_claim_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'results.json').write_text(json.dumps([{'status': 0}]))
            (root / 'matrix.json').write_text(json.dumps([{'passed': True}]))
            (root / 'metadata.json').write_text(json.dumps({'phase': 'tls', 'components': ['swift-nio-ssl']}))
            result = review(root)
            self.assertTrue(result['completed'])
            self.assertFalse(result['compatibility_measured'])
            self.assertIsNone(result['compatible'])
            self.assertEqual(result['components'], ['swift-nio-ssl'])

    def test_extra_failure_or_timeout_is_not_an_expected_difference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / 'comparison.events.tests/0'
            reports.mkdir(parents=True)
            index = reports.parent / 'index.json'
            index.write_text(json.dumps([{'status': 'FAILED'}]))
            suite = ET.Element('testsuite')
            for name, message in DIFFERENCES[('container', 'ContainerResourceTests')].items():
                ET.SubElement(ET.SubElement(suite, 'testcase', name=name), 'failure', message=message)
            path = reports / 'test.xml'
            ET.ElementTree(suite).write(path)
            log = root / 'test.log'
            log.write_text('original assertion failure')
            row = {'log': str(log), 'component': 'container', 'fixture': 'ContainerResourceTests', 'lane': 'fork',
                   'status': 3, 'events': str(root / 'comparison.events.json')}
            self.assertTrue(known_difference(row))
            log.write_text('Fatal error: teardown')
            self.assertFalse(known_difference(row))
            log.write_text('original assertion failure')
            self.assertFalse(known_difference(dict(row, status=124)))
            self.assertFalse(known_difference(dict(row, lane='stock')))
            index.write_text(json.dumps([{'status': 'TIMEOUT'}]))
            self.assertFalse(known_difference(row))
            index.write_text(json.dumps([{'status': 'FAILED'}]))
            ET.SubElement(ET.SubElement(suite, 'testcase', name='unexpected'), 'failure', message='new regression')
            ET.ElementTree(suite).write(path)
            self.assertFalse(known_difference(row))


if __name__ == '__main__':
    unittest.main()
