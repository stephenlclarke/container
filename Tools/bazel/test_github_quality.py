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
        self.codeql_job = dict(self.job, id=35, name='Analyze CodeQL',
                               html_url='https://github.com/example/job/35')

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
                            json.dumps(response), json.dumps({'jobs': [self.job, self.codeql_job]})]):
                    if outcome == 'success':
                        quality.run(evidence, timeout=0)
                    else:
                        with self.assertRaises(RuntimeError):
                            quality.run(evidence, timeout=0)
                report = json.loads((evidence / 'quality.json').read_text())
                self.assertEqual(report['passed'], outcome == 'success')
                if outcome == 'success':
                    self.assertEqual(set(report['analysis_jobs']), {'Analyze Swift', 'Analyze CodeQL'})

    def test_pending_job_can_complete_without_rerunning_tests(self):
        pending = dict(self.run, status='in_progress', conclusion=None)
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(quality, 'checkpoint', return_value='a' * 40), \
                patch.object(quality, 'analysis_context', return_value=self.context), \
                patch.object(quality.subprocess, 'check_output', side_effect=[
                    json.dumps({'workflow_runs': [pending]}), json.dumps({'workflow_runs': [self.run]}),
                    json.dumps({'jobs': [self.job, self.codeql_job]})]) as api, \
                patch.object(quality.time, 'sleep') as wait:
            quality.run(Path(directory) / 'quality')
            self.assertEqual(api.call_count, 3)
            wait.assert_called_once()

    def run_with_fake_clock(self, complete_at, conclusion='success', api_seconds=0):
        elapsed = 0
        pending = dict(self.run, status='in_progress', conclusion=None)

        def sleep(seconds):
            nonlocal elapsed
            elapsed += seconds

        def context(_revision):
            sleep(api_seconds)
            return self.context

        def response(command, **_kwargs):
            sleep(api_seconds)
            if '/jobs?' in command[4]:
                return json.dumps({'jobs': [self.job, self.codeql_job]})
            selected = (dict(self.run, conclusion=conclusion)
                        if complete_at is not None and elapsed >= complete_at else pending)
            return json.dumps({'workflow_runs': [selected]})

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(quality, 'checkpoint', return_value='a' * 40), \
                patch.object(quality, 'analysis_context', side_effect=context), \
                patch.object(quality.subprocess, 'check_output', side_effect=response) as api, \
                patch.object(quality.time, 'monotonic', side_effect=lambda: elapsed), \
                patch.object(quality.time, 'sleep', side_effect=sleep) as wait:
            evidence = Path(directory) / 'quality'
            if complete_at is None or conclusion != 'success':
                message = 'still pending' if complete_at is None else 'did not pass'
                with self.assertRaisesRegex(RuntimeError, message):
                    quality.run(evidence)
            else:
                quality.run(evidence)
            report = json.loads((evidence / 'quality.json').read_text())
        return elapsed, report, api, wait

    def test_default_wait_admits_success_after_thirty_minutes_before_ninety(self):
        elapsed, report, api, _wait = self.run_with_fake_clock(80 * 60)
        self.assertEqual(elapsed, 80 * 60)
        self.assertTrue(report['passed'])
        self.assertEqual(set(report['analysis_jobs']), {'Analyze Swift', 'Analyze CodeQL'})
        self.assertEqual(sum('/jobs?' in call.args[0][4] for call in api.call_args_list), 1)

    def test_near_deadline_success_with_bounded_api_latency_fits_outer_budget(self):
        elapsed, report, api, _wait = self.run_with_fake_clock(5420, api_seconds=29)
        self.assertGreater(elapsed, quality.DEFAULT_WAIT_SECONDS + 60)
        self.assertLess(elapsed, quality.DEFAULT_WAIT_SECONDS + 180)
        self.assertTrue(report['passed'])
        self.assertEqual(set(report['analysis_jobs']), {'Analyze Swift', 'Analyze CodeQL'})
        self.assertEqual(sum('/jobs?' in call.args[0][4] for call in api.call_args_list), 1)

    def test_default_wait_rejects_pending_at_ninety_minutes(self):
        elapsed, report, api, _wait = self.run_with_fake_clock(None)
        self.assertEqual(quality.DEFAULT_WAIT_SECONDS, 90 * 60)
        self.assertEqual(elapsed, 90 * 60)
        self.assertFalse(report['passed'])
        self.assertEqual(report['run']['status'], 'in_progress')
        self.assertFalse(any('/jobs?' in call.args[0][4] for call in api.call_args_list))

    def test_terminal_failure_does_not_wait_for_budget(self):
        elapsed, report, api, wait = self.run_with_fake_clock(0, 'failure')
        self.assertEqual(elapsed, 0)
        self.assertFalse(report['passed'])
        self.assertEqual(report['run']['conclusion'], 'failure')
        self.assertEqual(api.call_count, 1)
        wait.assert_not_called()

    def test_skipped_missing_failed_or_wrong_revision_analysis_cannot_qualify(self):
        for name in ('Analyze Swift', 'Analyze CodeQL'):
            for change in ('missing', 'skipped', 'failure', 'pending', 'wrong-revision', 'duplicate'):
                jobs = [self.job, self.codeql_job]
                selected = next(job for job in jobs if job['name'] == name)
                if change == 'missing':
                    jobs = [job for job in jobs if job['name'] != name]
                elif change == 'duplicate':
                    jobs = [*jobs, selected]
                else:
                    field, value = {
                        'skipped': ('conclusion', 'skipped'),
                        'failure': ('conclusion', 'failure'),
                        'pending': ('status', 'in_progress'),
                        'wrong-revision': ('head_sha', 'b' * 40),
                    }[change]
                    jobs = [dict(job, **{field: value}) if job['name'] == name else job for job in jobs]
                with self.subTest(name=name, change=change), \
                        patch.object(quality.subprocess, 'check_output',
                                     return_value=json.dumps({'jobs': jobs})):
                    with self.assertRaisesRegex(RuntimeError, 'actually pass'):
                        quality.require_analysis_jobs(self.run, 'a' * 40)

    def test_both_jobs_must_belong_to_selected_attempt(self):
        selected = dict(self.run, run_attempt=2)
        with patch.object(quality.subprocess, 'check_output',
                          return_value=json.dumps({'jobs': [self.job, self.codeql_job]})) as api:
            admitted = quality.require_analysis_jobs(selected, 'a' * 40)
        self.assertEqual(set(admitted), {'Analyze Swift', 'Analyze CodeQL'})
        self.assertIn('/runs/12/attempts/2/jobs?', api.call_args.args[0][4])


if __name__ == '__main__':
    unittest.main()
