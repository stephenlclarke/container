"""Empty or foreign reports must not masquerade as container source coverage."""

import unittest

from coverage import normalize_lcov


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


if __name__ == '__main__':
    unittest.main()
