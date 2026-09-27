"""Check that paired reporting retains failures and compares matching fixtures."""

import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from fork_benchmark import Runner, tls_samples


class ReportTests(unittest.TestCase):
    def test_tls_accepts_ten_completed_release_samples(self):
        text = 'measuring: repeated_handshakes: ' + '0.125, ' * 10 + '\n'
        self.assertEqual(tls_samples(text, 'repeated_handshakes'), [0.125] * 10)

    def test_tls_rejects_debug_skipped_incomplete_or_invalid_measurements(self):
        good = 'measuring: repeated_handshakes: ' + '0.125, ' * 10 + '\n'
        for text in ('DEBUG MODE\n' + good, 'skipping repeated_handshakes', good + good,
                     good.replace('repeated_handshakes', 'many_writes_512b'),
                     good.replace('0.125, ', '', 1), good.replace('0.125', 'nan', 1),
                     good.replace('0.125', 'inf', 1), good.replace('0.125', '0', 1)):
            with self.subTest(output=text), self.assertRaises(ValueError):
                tls_samples(text, 'repeated_handshakes')

    def test_successful_command_does_not_sleep_polling_for_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            # A measurement must not acquire a delay from the parent's timeout
            # polling loop. This deterministically catches the old implementation.
            with patch('subprocess.time.sleep', side_effect=AssertionError('polling delay')):
                row = runner.run('probe', 'fork', 'precise-exit', 0,
                                 [sys.executable, '-c', 'pass'], evidence, timeout=5)
            self.assertEqual(row['status'], 0)

    def test_command_preserves_output_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            row = runner.run('probe', 'fork', 'exit', 0,
                             [sys.executable, '-c', 'print("retained-output"); raise SystemExit(7)'],
                             evidence, timeout=5)
            self.assertEqual(row['status'], 7)
            self.assertIn('retained-output', Path(row['log']).read_text())

    def test_deadline_kills_and_reaps_child_and_retains_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            row = runner.run('probe', 'fork', 'timeout', 0,
                             [sys.executable, '-c', 'import time; print("started", flush=True); time.sleep(30)'],
                             evidence, timeout=0.5)
            self.assertEqual(row['status'], 124)
            self.assertLess(row['seconds'], 5)
            self.assertIn('started', Path(row['log']).read_text())
            self.assertEqual(json.loads((evidence / 'results.json').read_text())[0]['status'], 124)

    def test_timeout_terminates_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            marker = evidence / 'orphan-survived'
            child = 'import time,pathlib; time.sleep(1.5); pathlib.Path(' + repr(str(marker)) + ').touch()'
            parent = ('import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' +
                      repr(child) + ']); time.sleep(30)')
            with patch('threading.excepthook') as errors:
                row = runner.run('probe', 'fork', 'descendant-timeout', 0,
                                 [sys.executable, '-c', parent], evidence, timeout=0.5)
            errors.assert_not_called()
            self.assertEqual(row['status'], 124)
            import time
            time.sleep(1.5)
            self.assertFalse(marker.exists())

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
            self.assertEqual([r['ratio'] for r in matrix], [10, None])
            self.assertFalse(any(r['passed'] for r in matrix))
            junit = ET.parse(evidence / 'timings.xml')
            self.assertEqual(len(list(junit.iter('failure'))), 2)
            self.assertEqual(len(json.loads((evidence / 'results.json').read_text())), 6)


if __name__ == '__main__':
    unittest.main()
