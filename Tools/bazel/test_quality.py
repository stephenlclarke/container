"""Reject mutable source or drifted remote policy before submitting an analysis."""

import unittest
from copy import deepcopy
from unittest.mock import patch

from quality import REPOSITORY, checkpoint, context_arguments, pull_request_context, validate_policy


class QualityAdmissionTests(unittest.TestCase):
    def test_pr_analysis_requires_exact_open_pushed_checkpoint(self):
        revision = 'a' * 40
        pull = {'number': 289, 'state': 'open',
                'head': {'repo': {'full_name': REPOSITORY}, 'ref': 'build/example', 'sha': revision},
                'base': {'repo': {'full_name': REPOSITORY}, 'ref': 'main', 'sha': 'b' * 40}}
        context = pull_request_context([pull], 'build/example', revision)
        self.assertEqual(context['key'], '289')
        self.assertEqual(context['base_revision'], 'b' * 40)
        self.assertEqual(context_arguments(context), ['-Dsonar.pullrequest.key=289',
                         '-Dsonar.pullrequest.branch=build/example', '-Dsonar.pullrequest.base=main'])
        for side, key, value in [('head', 'sha', 'c' * 40), ('head', 'ref', 'other'),
                                 ('base', 'ref', 'develop'), ('head', 'repo', {'full_name': 'apple/container'}),
                                 ('base', 'repo', {'full_name': 'apple/container'})]:
            changed = deepcopy(pull)
            changed[side][key] = value
            with self.subTest(side=side, key=key), self.assertRaisesRegex(RuntimeError, 'does not match'):
                pull_request_context([changed], 'build/example', revision)
        for state in ('closed', 'merged'):
            with self.subTest(state=state), self.assertRaisesRegex(RuntimeError, 'does not match'):
                pull_request_context([dict(pull, state=state)], 'build/example', revision)
        for pulls in ([], [pull, pull]):
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                pull_request_context(pulls, 'build/example', revision)

    def test_main_context_uses_branch_analysis(self):
        self.assertEqual(context_arguments({'kind': 'branch', 'branch': 'main'}), ['-Dsonar.branch.name=main'])

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
