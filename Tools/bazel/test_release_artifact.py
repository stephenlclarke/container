"""Release packaging must reject stale products and failed notarization."""

import json
from pathlib import Path
import tempfile
import unittest

from fork_benchmark import digest
from release_artifact import copy_products, notarize


class ReleaseArtifactTests(unittest.TestCase):
    def test_product_checksum_is_checked_before_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / 'install/bin'
            install.mkdir(parents=True)
            binary = install / 'container'
            binary.write_bytes(b'qualified binary')
            (root / 'fork-fingerprint.json').write_text(json.dumps({
                'install': str(install.parent), 'binaries': {'bin/container': digest(binary)}}))
            copy_products(root, root / 'valid')
            self.assertEqual((root / 'valid/container').read_bytes(), binary.read_bytes())
            binary.write_bytes(b'replaced binary')
            with self.assertRaisesRegex(RuntimeError, 'output changed'):
                copy_products(root, root / 'invalid')
            self.assertFalse((root / 'invalid/container').exists())

    def test_notary_submission_is_retained_before_wait_and_invalid_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            class NotaryRunner:
                evidence = root

                def run(self, _component, _lane, fixture, _trial, _args, _cwd, _timeout):
                    if fixture == 'notary-wait':
                        self_record = json.loads((root / 'notary-submission.json').read_text())
                        if self_record['id'] != 'submission-123':
                            raise AssertionError('Submission ID was not persisted')
                    path = root / (fixture + '.log')
                    path.write_text(json.dumps({'id': 'submission-123', 'status': 'Invalid'}))
                    return {'status': 0, 'log': str(path)}

            with self.assertRaisesRegex(RuntimeError, 'did not reach Accepted'):
                notarize(NotaryRunner(), root / 'archive.zip', 'profile')
            self.assertEqual(json.loads((root / 'notary-status.json').read_text())['status'], 'Invalid')
            self.assertTrue((root / 'notary-log.log').exists())


if __name__ == '__main__':
    unittest.main()
