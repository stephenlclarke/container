"""Empty or foreign reports must not masquerade as container source coverage."""

import unittest

import json
from pathlib import Path
import tempfile

from combined_coverage import qualified_report
from coverage import line_counts, merge_lcov, normalize_lcov
from fork_benchmark import digest


class CoverageTests(unittest.TestCase):
    def test_maps_container_records_and_excludes_other_dependencies(self):
        report = ('SF:external/+dependencies+swiftpkg_container/Sources/A.swift\nDA:7,2\nend_of_record\n'
                  'SF:external/+dependencies+swiftpkg_other/Sources/B.swift\nDA:1,1\nend_of_record\n')
        self.assertEqual(normalize_lcov(report), 'SF:Sources/A.swift\nDA:7,2\nend_of_record\n')

    def test_empty_baseline_and_unexecuted_reports_fail(self):
        for record in ('LF:0', 'DA:1,0'):
            with self.subTest(record=record), self.assertRaisesRegex(RuntimeError, 'no covered executable'):
                normalize_lcov('SF:Sources/A.swift\n' + record + '\nend_of_record\n')

    def test_path_escape_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'escapes'):
            normalize_lcov('SF:Sources/../../foreign.swift\nDA:1,1\nend_of_record\n')

    def test_combined_report_preserves_uncovered_lines_and_unions_hits(self):
        unit = 'SF:Sources/A.swift\nDA:1,2\nDA:2,0\nDA:3,0\nend_of_record\n'
        integration = ('SF:Sources/A.swift\nDA:1,3\nDA:2,4\nend_of_record\n'
                       'SF:Sources/B.swift\nDA:5,1\nend_of_record\n')
        result = line_counts(merge_lcov([unit, integration]))
        self.assertEqual(result, {'Sources/A.swift': {1: 5, 2: 4, 3: 0}, 'Sources/B.swift': {5: 1}})
        for reports in ([], [unit, ''], [unit, unit.replace('DA:1,2', 'DA:1,0')]):
            with self.subTest(reports=reports), self.assertRaises(RuntimeError):
                merge_lcov(reports)

    def test_valid_zero_counter_source_is_preserved_with_a_covered_source(self):
        report = ('SF:Sources/CAuditToken/AuditToken.c\nLF:0\nLH:0\nend_of_record\n'
                  'SF:Sources/A.swift\nDA:1,2\nend_of_record\n')
        self.assertEqual(line_counts(merge_lcov([report])),
                         {'Sources/CAuditToken/AuditToken.c': {}, 'Sources/A.swift': {1: 2}})

    def test_combining_rejects_partial_drifted_or_modified_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lcov = root / 'coverage.lcov'
            lcov.write_text('SF:Sources/A.swift\nDA:1,2\nend_of_record\n')
            sources = {'Sources/A.swift': 'source-hash'}
            record = dict(passed=True, full_suite=True, restored=True, source_files=sources,
                          reports={'coverage.lcov': digest(lcov)})
            receipt = root / 'coverage.json'
            receipt.write_text(json.dumps(record))
            self.assertEqual(qualified_report(root, sources, True), lcov.read_text())
            for change in ({'passed': False}, {'full_suite': False}, {'restored': False}, {'source_files': {}}):
                receipt.write_text(json.dumps(dict(record, **change)))
                with self.subTest(change=change), self.assertRaises(RuntimeError):
                    qualified_report(root, sources, True)
            receipt.write_text(json.dumps(record))
            lcov.write_text(lcov.read_text().replace('DA:1,2', 'DA:1,999'))
            with self.assertRaisesRegex(RuntimeError, 'report changed'):
                qualified_report(root, sources, True)


if __name__ == '__main__':
    unittest.main()
