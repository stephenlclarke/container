"""A failed gate blocks dependent publication work while independent evidence continues."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import qualification


class QualificationTests(unittest.TestCase):
    def test_quality_requires_complete_combined_coverage(self):
        for failed in ('integration', 'combined-coverage', None):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                commands = {}

                def execute(component, lane, fixture, trial, command, cwd, timeout):
                    commands[fixture] = command
                    return {'status': int(fixture == failed), 'log': fixture + '.log', 'seconds': 1}

                with patch.object(qualification, 'checkpoint', return_value='a' * 40), \
                        patch.object(qualification.Runner, 'run', side_effect=execute):
                    if failed:
                        with self.assertRaises(SystemExit):
                            qualification.run(evidence, 1)
                    else:
                        qualification.run(evidence, 1)
                report = json.loads((evidence / 'qualification.json').read_text())
                quality = next(row for row in report['stages'] if row['name'] == 'quality')
                if failed:
                    self.assertNotIn('quality', commands)
                    self.assertEqual(quality['blocked_by'], ['combined-coverage'])
                else:
                    command = commands['quality']
                    self.assertEqual(command[command.index('--coverage') + 1], str(evidence / 'combined-coverage'))
                    self.assertEqual(quality['state'], 'passed')

    def test_failed_gate_is_retained_and_blocks_only_its_dependents(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            stages = [('quality', [], ['false'], 1), ('release', ['quality'], ['must-not-run'], 1),
                      ('independent', [], ['true'], 1)]
            rows = [{'status': 1, 'log': 'quality.log', 'seconds': 1},
                    {'status': 0, 'log': 'independent.log', 'seconds': 2}]
            with patch.object(qualification, 'stages', return_value=stages), \
                    patch.object(qualification, 'checkpoint', return_value='a' * 40), \
                    patch.object(qualification.Runner, 'run', side_effect=rows) as command:
                with self.assertRaises(SystemExit):
                    qualification.run(evidence, 1)
            report = json.loads((evidence / 'qualification.json').read_text())
            self.assertFalse(report['passed'])
            self.assertEqual([row['state'] for row in report['stages']], ['failed', 'blocked', 'passed'])
            self.assertEqual(report['stages'][1]['blocked_by'], ['quality'])
            self.assertEqual(command.call_count, 2)

    def test_existing_failure_evidence_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            receipt = evidence / 'qualification.json'
            receipt.write_text('{"passed": false}')
            with self.assertRaisesRegex(RuntimeError, 'previous failures'):
                qualification.run(evidence, 1)
            self.assertEqual(receipt.read_text(), '{"passed": false}')


if __name__ == '__main__':
    unittest.main()
