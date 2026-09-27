"""VM integration keeps nonempty results, failures and platform skips distinct."""

from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from vm_integration import retain_results


class VMResultsTests(unittest.TestCase):
    def test_failures_and_skips_remain_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'run.log'
            log.write_text('test boot complete in 0.45s.\n'
                           'test exec failed: wrong exit status\n'
                           'skipped test: GPU unavailable\n'
                           'Integration suite completed in 1.0s with 1/3 passed and 1/3 skipped!\n')
            result = retain_results(log, root)
            self.assertEqual(result, {'passed_tests': 1, 'total_tests': 3, 'skipped_tests': 1})
            xml = ET.parse(root / 'tests.xml')
            self.assertEqual(len(list(xml.iter('failure'))), 1)
            self.assertEqual(len(list(xml.iter('skipped'))), 1)
            log.write_text('Integration suite completed in 0.0s with 0/0 passed!')
            with self.assertRaisesRegex(RuntimeError, 'nonempty'):
                retain_results(log, root)


if __name__ == '__main__':
    unittest.main()
