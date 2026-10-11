"""Protect the retained-reference stopped-copy timing admission boundary."""

import unittest

from stopped_copy import timing_pairs


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
