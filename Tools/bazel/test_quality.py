"""Reject mutable source or drifted remote policy before submitting an analysis."""

import unittest
from unittest.mock import patch

from quality import checkpoint, validate_policy


class QualityAdmissionTests(unittest.TestCase):
    def test_both_remote_policy_settings_are_required(self):
        settings = {'settings': [{'key': key, 'value': 'previous_version'}
                                 for key in ('sonar.leak.period', 'sonar.leak.period.type')]}
        validate_policy(settings)
        settings['settings'].pop()
        with self.assertRaisesRegex(RuntimeError, 'Previous version'):
            validate_policy(settings)

    def test_dirty_checkpoint_is_rejected_before_version_lookup(self):
        with patch('quality.subprocess.check_output', return_value=' M Sources/changed.swift\n') as command:
            with self.assertRaisesRegex(RuntimeError, 'clean, committed'):
                checkpoint()
            self.assertEqual(command.call_count, 1)


if __name__ == '__main__':
    unittest.main()
