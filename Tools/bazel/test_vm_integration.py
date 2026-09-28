"""VM integration keeps nonempty results, failures and platform skips distinct."""

from pathlib import Path
import hashlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

from vm_integration import GPU_SKIP_REASON, retain_results, stage_runc, validate_skips


class VMResultsTests(unittest.TestCase):
    def test_failures_and_skips_remain_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'run.log'
            log.write_text('test boot complete in 4.5e-05s.\n'
                           'test exec failed: wrong exit status\n'
                           'test graphics started...\n'
                           'skipped test: GPU unavailable\n'
                           'Integration suite completed in 1.0s with 1/3 passed and 1/3 skipped!\n')
            result = retain_results(log, root)
            self.assertEqual(result, {'passed_tests': 1, 'total_tests': 3, 'skipped_tests': 1,
                                     'skips': [{'test': 'graphics', 'reason': 'GPU unavailable'}]})
            xml = ET.parse(root / 'tests.xml')
            self.assertEqual(len(list(xml.iter('failure'))), 1)
            self.assertEqual(len(list(xml.iter('skipped'))), 1)
            self.assertEqual(list(xml.iter('testcase'))[0].get('time'), '4.5e-05')
            log.write_text('Integration suite completed in 0.0s with 0/0 passed!')
            with self.assertRaisesRegex(RuntimeError, 'nonempty'):
                retain_results(log, root)

    def test_summary_cannot_hide_missing_individual_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'run.log'
            log.write_text('test boot complete in 0.45s.\n'
                           'Integration suite completed in 1.0s with 2/2 passed!\n')
            with self.assertRaisesRegex(RuntimeError, 'disagree'):
                retain_results(log, root)

    def test_only_named_unsupported_graphics_skips_are_accepted(self):
        allowed = {'test': 'container virtio graphics device attachment', 'reason': GPU_SKIP_REASON}
        validate_skips({'skips': [allowed]})
        for skip in [dict(allowed, test='runc process true'), dict(allowed, reason='bin/runc-arm64 missing')]:
            with self.subTest(skip=skip), self.assertRaisesRegex(RuntimeError, 'skipped required tests'):
                validate_skips({'skips': [skip]})

    def test_vm_host_fixture_must_match_runc_guest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'runc'
            binary.write_bytes(b'runtime')
            sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            pin = {'version': 'v1.5.1', 'sha256': sha}
            guest = {'identity': {'runc': pin}, 'runc_binary': str(binary), 'binaries': {'runc': sha}}
            destination = root / 'bin'
            destination.mkdir()
            self.assertEqual(stage_runc(guest, destination), pin)
            self.assertEqual((destination / 'runc-arm64').read_bytes(), binary.read_bytes())
            binary.write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                stage_runc(guest, destination)
            with self.assertRaisesRegex(RuntimeError, 'requires a guest'):
                stage_runc({'identity': {}}, destination)


if __name__ == '__main__':
    unittest.main()
