"""Hosted authority must match the current commit and its newest workflow run."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import github_quality as quality


class GitHubQualityTests(unittest.TestCase):
    def setUp(self):
        self.context = dict(kind='pull_request', key='289', base='main', base_revision='b' * 40,
                            branch='build/example', revision='a' * 40)
        self.run = dict(id=12, run_attempt=1, head_sha='a' * 40, head_branch='build/example',
                        run_started_at='2026-09-28T12:00:00Z', updated_at='2026-09-28T12:10:00Z',
                        event='pull_request', repository={'full_name': quality.REPOSITORY},
                        head_repository={'full_name': quality.REPOSITORY}, status='completed',
                        conclusion='success', html_url='https://github.com/example/run/12',
                        pull_requests=[dict(number=289, head={'sha': 'a' * 40},
                                            base={'sha': 'b' * 40, 'ref': 'main'})])
        self.job = dict(id=34, name='Analyze Swift', head_sha='a' * 40, status='completed',
                        conclusion='success', html_url='https://github.com/example/job/34')

    def test_latest_failed_or_pending_run_outranks_old_success(self):
        for status, conclusion in [('completed', 'failure'), ('in_progress', None)]:
            newer = dict(self.run, id=13, status=status, conclusion=conclusion)
            self.assertEqual(quality.select_run([newer, self.run], self.context), newer)
            rerun = dict(newer, id=11, run_attempt=2, run_started_at='2026-09-28T12:05:00Z',
                         updated_at='2026-09-28T12:05:00Z')
            self.assertEqual(quality.select_run([rerun, self.run], self.context), rerun)

    def test_main_must_match_current_pushed_head(self):
        context = dict(kind='branch', branch='main', revision='a' * 40)
        for revision in ('a' * 40, 'b' * 40):
            with patch.object(quality, 'analysis_context', return_value=context), \
                    patch.object(quality.subprocess, 'check_output',
                                 return_value=json.dumps({'object': {'sha': revision}})):
                if revision == context['revision']:
                    self.assertEqual(quality.current_context(revision), context)
                else:
                    with self.assertRaisesRegex(RuntimeError, 'current pushed main'):
                        quality.current_context(context['revision'])

    def test_wrong_commit_branch_repository_and_diagnostic_events_are_rejected(self):
        for key, value in [('head_sha', 'b' * 40), ('head_branch', 'other'), ('event', 'workflow_dispatch'),
                           ('repository', {'full_name': 'other/repo'}), ('head_repository', {'full_name': 'other/repo'}),
                           ('pull_requests', []), ('pull_requests', [dict(number=290)]),
                           ('pull_requests', [dict(number=289, head={'sha': 'a' * 40},
                                                  base={'sha': 'c' * 40, 'ref': 'main'})])]:
            with self.subTest(key=key):
                self.assertIsNone(quality.select_run([dict(self.run, **{key: value})], self.context))
        context = dict(self.context, kind='branch', branch='main')
        main = dict(self.run, head_branch='main', event='push')
        self.assertEqual(quality.select_run([main], context), main)

    def test_success_failure_pending_and_context_drift_are_retained(self):
        for outcome in ('success', 'failure', 'pending', 'missing', 'drift'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory) / 'quality'
                row = dict(self.run)
                if outcome == 'failure':
                    row['conclusion'] = 'failure'
                if outcome == 'pending':
                    row.update(status='in_progress', conclusion=None)
                contexts = [self.context, dict(self.context, revision='b' * 40)] if outcome == 'drift' else [self.context, self.context]
                response = {'workflow_runs': [] if outcome == 'missing' else [row]}
                with patch.object(quality, 'checkpoint', return_value='a' * 40), \
                        patch.object(quality, 'analysis_context', side_effect=contexts), \
                        patch.object(quality.subprocess, 'check_output', side_effect=[
                            json.dumps(response), json.dumps({'jobs': [self.job]})]):
                    if outcome == 'success':
                        quality.run(evidence, timeout=0)
                    else:
                        with self.assertRaises(RuntimeError):
                            quality.run(evidence, timeout=0)
                report = json.loads((evidence / 'quality.json').read_text())
                self.assertEqual(report['passed'], outcome == 'success')

    def test_pending_job_can_complete_without_rerunning_tests(self):
        pending = dict(self.run, status='in_progress', conclusion=None)
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(quality, 'checkpoint', return_value='a' * 40), \
                patch.object(quality, 'analysis_context', return_value=self.context), \
                patch.object(quality.subprocess, 'check_output', side_effect=[
                    json.dumps({'workflow_runs': [pending]}), json.dumps({'workflow_runs': [self.run]}),
                    json.dumps({'jobs': [self.job]})]) as api, \
                patch.object(quality.time, 'sleep') as wait:
            quality.run(Path(directory) / 'quality')
            self.assertEqual(api.call_count, 3)
            wait.assert_called_once()

    def test_skipped_missing_failed_or_wrong_revision_analysis_cannot_qualify(self):
        for jobs in ([], [dict(self.job, conclusion='skipped')], [dict(self.job, conclusion='failure')],
                     [dict(self.job, status='in_progress')], [dict(self.job, head_sha='b' * 40)],
                     [self.job, self.job]):
            with self.subTest(jobs=jobs), patch.object(quality.subprocess, 'check_output',
                                                     return_value=json.dumps({'jobs': jobs})):
                with self.assertRaisesRegex(RuntimeError, 'actually pass'):
                    quality.require_analysis_job(self.run, 'a' * 40)


if __name__ == '__main__':
    unittest.main()
