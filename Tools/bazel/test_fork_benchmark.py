"""Check that paired reporting retains failures and compares matching fixtures."""

import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from fork_benchmark import Runner


class ReportTests(unittest.TestCase):
    def test_median_does_not_hide_a_tenfold_trial(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            for trial, seconds in enumerate([1, 10, 1]):
                for lane, duration in [('stock', 1), ('fork', seconds)]:
                    runner.rows.append(dict(component='container', lane=lane,
                                            fixture='build', seconds=duration, status=0,
                                            trial=trial, log='retained.log'))
            runner.report()
            row = json.loads((evidence / 'matrix.json').read_text())[0]
            self.assertEqual(row['ratio'], 1)
            self.assertEqual(row['worst_trial_ratio'], 10)
            self.assertFalse(row['passed'])

    def test_matching_fixture_regression_and_failure_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            for lane, name, seconds, status in [
                ('stock', 'prepare-build', 100, 0),
                ('fork', 'prepare-build', 1, 0),
                ('stock', 'archive', 1, 0),
                ('fork', 'archive', 10, 0),
                ('stock', 'oci', 2, 0),
                ('fork', 'oci', 3, 1),
            ]:
                runner.rows.append(dict(component='containerization', lane=lane,
                                        fixture=name, seconds=seconds, status=status,
                                        trial=0, log='retained.log'))
            runner.report()
            matrix = json.loads((evidence / 'matrix.json').read_text())
            self.assertEqual([r['fixture'] for r in matrix], ['archive', 'oci'])
            self.assertEqual([r['ratio'] for r in matrix], [10, 1.5])
            self.assertFalse(any(r['passed'] for r in matrix))
            junit = ET.parse(evidence / 'timings.xml')
            self.assertEqual(len(list(junit.iter('failure'))), 2)
            self.assertEqual(len(json.loads((evidence / 'results.json').read_text())), 6)


if __name__ == '__main__':
    unittest.main()
