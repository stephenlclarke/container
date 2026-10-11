"""Protect the retained-reference stopped-copy timing admission boundary."""

import unittest

from stopped_copy import timing_pairs, workload_log_payloads


class StoppedCopyLogTests(unittest.TestCase):
    def test_empty_create_metadata_is_not_a_workload_record(self):
        files = {'logging-v2/history-sequence-v1.bin': {'size': 57, 'sha256': 'metadata'},
                 'logging-v2/process-generation-v1.bin': {'size': 48, 'sha256': 'generation'},
                 'logging-v2/json-file/json.log': {'size': 0, 'sha256': 'empty'}}
        self.assertEqual(workload_log_payloads(files), {})

    def test_nonempty_current_rotated_and_legacy_logs_are_all_observed(self):
        names = ['stdio.log', 'stdio.jsonl.1', 'logging-v2/json-file/json.log',
                 'logging-v2/json-file/json.log.1']
        files = {name: {'size': 9, 'sha256': name} for name in names}
        self.assertEqual(workload_log_payloads(files), files)

    def test_payload_changes_cannot_be_hidden_as_metadata_initialization(self):
        before = {'logging-v2/json-file/json.log': {'size': 3, 'sha256': 'old'}}
        after = {'logging-v2/json-file/json.log': {'size': 3, 'sha256': 'new'}}
        self.assertNotEqual(workload_log_payloads(before), workload_log_payloads(after))


class StoppedCopyTimingTests(unittest.TestCase):
    def reference(self, seconds=0.1, status=0):
        return {'operations': [{'fixture': 'copy-file', 'seconds': seconds, 'status': status}]}

    def candidate(self, seconds, status=0, fixture='copy-file'):
        return {'fixture': fixture, 'seconds': seconds, 'status': status}

    def test_ordinary_slowdown_is_informational_but_exact_tenfold_fails(self):
        self.assertTrue(timing_pairs([self.candidate(.999)], self.reference())[0]['passed'])
        self.assertFalse(timing_pairs([self.candidate(1.)], self.reference())[0]['passed'])

    def test_failed_copy_cannot_pass_on_speed(self):
        self.assertFalse(timing_pairs([self.candidate(.01, status=1)], self.reference())[0]['passed'])

    def test_unrelated_setup_is_not_used_as_reference(self):
        self.assertEqual(timing_pairs([self.candidate(1., fixture='setup')], self.reference()), [])

    def test_nonpositive_nonfinite_and_boolean_durations_are_refused(self):
        for invalid in (0, -1, float('inf'), float('nan'), True):
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                timing_pairs([self.candidate(invalid)], self.reference())
            with self.subTest(reference=invalid), self.assertRaises(ValueError):
                timing_pairs([self.candidate(.1)], self.reference(seconds=invalid))

    def test_duplicate_or_failed_references_and_duplicate_candidates_are_refused(self):
        reference = self.reference()
        reference['operations'] *= 2
        with self.assertRaises(ValueError):
            timing_pairs([self.candidate(.1)], reference)
        with self.assertRaises(ValueError):
            timing_pairs([self.candidate(.1)], self.reference(status=1))
        with self.assertRaises(ValueError):
            timing_pairs([self.candidate(.1)] * 2, self.reference())


if __name__ == '__main__':
    unittest.main()
