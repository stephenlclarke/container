"""An extracted package must match the signed and retained payload exactly."""

import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from fork_benchmark import digest
from release_install import checked_payload


class ReleaseInstallTests(unittest.TestCase):
    def test_changed_and_additional_package_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'container'
            source.write_bytes(b'original executable')
            expected = {'bin/container': digest(source)}
            archive = root / 'archive.tar'
            with tarfile.open(archive, 'w') as package:
                package.add(source, arcname='bin/container')
            checked_payload(archive, root / 'valid', expected)
            with tarfile.open(archive, 'a') as package:
                extra = tarfile.TarInfo('bin/unexpected')
                extra.size = 3
                package.addfile(extra, io.BytesIO(b'bad'))
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                checked_payload(archive, root / 'extra', expected)


if __name__ == '__main__':
    unittest.main()
