"""Reject mutable source or drifted remote policy before submitting an analysis."""

import unittest
from copy import deepcopy
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

from fork_benchmark import digest
from quality import REPOSITORY, checkpoint, clean_code_checks, context_arguments, pull_request_context, validate_policy, verified_coverage


class QualityAdmissionTests(unittest.TestCase):
    def test_scan_rejects_partial_foreign_and_changed_coverage(self):
        with tempfile.TemporaryDirectory() as directory, patch('quality.source_files', return_value={'Sources/A.swift': 'source-hash'}):
            root = Path(directory)
            xml = root / 'coverage.xml'
            xml.write_text('<coverage version="1"/>')
            receipt = root / 'coverage.json'
            report = {'passed': True, 'kind': 'unit-and-full-integration',
                      'source_files': {'Sources/A.swift': 'source-hash'}, 'reports': {'coverage.xml': digest(xml)}}
            receipt.write_text(json.dumps(report))
            self.assertEqual(verified_coverage(root),
                             {'kind': report['kind'], 'receipt_sha256': digest(receipt),
                              'xml': str(xml), 'xml_sha256': digest(xml)})
            for change in ({'passed': False}, {'kind': None}, {'kind': 'unit'},
                           {'kind': 'integration', 'full_suite': False}, {'source_files': {}}):
                receipt.write_text(json.dumps(dict(report, **change)))
                with self.subTest(change=change), self.assertRaisesRegex(RuntimeError, 'passed combined coverage'):
                    verified_coverage(root)
            receipt.write_text(json.dumps(report))
            xml.write_text('<coverage version="1"><file path="changed"/></coverage>')
            with self.assertRaisesRegex(RuntimeError, 'report changed'):
                verified_coverage(root)

    def test_clean_code_checks_keep_pr_new_code_and_main_full_scope(self):
        for context, expected in [({'kind': 'pull_request', 'key': '289'},
                                   {'pullRequest': '289', 'inNewCodePeriod': 'true'}),
                                  ({'kind': 'branch', 'branch': 'main'}, {'branch': 'main'})]:
            with self.subTest(context=context), tempfile.TemporaryDirectory() as directory, \
                    patch('quality.api', side_effect=[{'total': 0}, {'paging': {'total': 0}}]) as api:
                evidence = Path(directory)
                self.assertEqual(clean_code_checks(context, evidence),
                                 {'unresolved_issues': 0, 'unreviewed_hotspots': 0})
                self.assertEqual(api.call_args_list[0].args, ('issues/search',
                                 {'componentKeys': 'stephenlclarke_container', 'resolved': 'false', 'ps': 1, **expected}))
                self.assertEqual(api.call_args_list[1].args, ('hotspots/search',
                                 {'projectKey': 'stephenlclarke_container', 'status': 'TO_REVIEW', 'ps': 1, **expected}))
                self.assertEqual(json.loads((evidence / 'unresolved-issues.json').read_text()), {'total': 0})
                self.assertEqual(json.loads((evidence / 'unreviewed-hotspots.json').read_text()), {'paging': {'total': 0}})

    def test_nonzero_or_missing_clean_code_counts_fail(self):
        for issues, hotspots in [(1, 0), (0, 1), (None, 0), (0, None), ('0', 0), (False, 0), (-1, 0)]:
            with self.subTest(issues=issues, hotspots=hotspots), tempfile.TemporaryDirectory() as directory, \
                    patch('quality.api', side_effect=[{'total': issues}, {'paging': {'total': hotspots}}]):
                with self.assertRaisesRegex(RuntimeError, 'zero unresolved issues'):
                    clean_code_checks({'kind': 'branch', 'branch': 'main'}, Path(directory))

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
