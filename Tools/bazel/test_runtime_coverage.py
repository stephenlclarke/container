"""Coverage failures must restore original products without replacing live binaries."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from fork_benchmark import digest
import runtime_coverage
from runtime_benchmark import RuntimeRunner


class RuntimeCoverageTests(unittest.TestCase):
    def test_setup_only_profiles_cannot_replace_runtime_service_coverage(self):
        cli = 'SF:Sources/ContainerCommands/Version.swift\nDA:1,1\nend_of_record\n'
        api = 'SF:Sources/APIServer/APIServer.swift\nDA:1,1\nend_of_record\n'
        runtime = 'SF:Sources/Services/RuntimeLinux/Server/RuntimeService.swift\nDA:1,2\nend_of_record\n'
        with self.assertRaisesRegex(RuntimeError, 'omitted exercised service'):
            runtime_coverage.validate_runtime_coverage(cli, False)
        with self.assertRaisesRegex(RuntimeError, 'omitted exercised service'):
            runtime_coverage.validate_runtime_coverage(cli + api, True)
        self.assertEqual(runtime_coverage.validate_runtime_coverage(cli + api + runtime, True),
                         {'Sources/APIServer/': 1, 'Sources/Services/RuntimeLinux/Server/': 1})

    def transaction(self, root: Path):
        evidence = root / 'evidence'
        evidence.mkdir()
        install = root / 'fork/install'
        install.mkdir(parents=True)
        product = install / 'container'
        product.write_text('original')
        (evidence / 'fork-fingerprint.json').write_text(json.dumps({'binaries': {'container': digest(product)}}))
        with patch.object(runtime_coverage, 'INSTALLS', root), patch.object(runtime_coverage, 'source_files', return_value={}):
            coverage = runtime_coverage.RuntimeCoverage(RuntimeRunner(evidence, root), False)
        temporary = root / 'fork/recovery'
        temporary.mkdir()
        backup = temporary / 'previous'
        install.rename(backup)
        install.mkdir()
        product.write_text('instrumented')
        coverage.backup = backup
        coverage.result['recovery_directory'] = str(temporary)
        return coverage, product, backup

    def test_export_failure_still_restores_and_verifies_original_binaries(self):
        with tempfile.TemporaryDirectory() as directory:
            coverage, product, backup = self.transaction(Path(directory))
            with patch.object(runtime_coverage, 'stop_owned'), patch.object(runtime_coverage, 'require_idle'), \
                    patch.object(runtime_coverage, 'own'), patch.object(coverage, 'export', side_effect=RuntimeError('bad profile')):
                with self.assertRaisesRegex(RuntimeError, 'bad profile'):
                    coverage.finish(True)
            self.assertEqual(product.read_text(), 'original')
            self.assertFalse(backup.exists())
            receipt = json.loads((coverage.evidence / 'coverage.json').read_text())
            self.assertTrue(receipt['restored'])
            self.assertFalse(receipt['passed'])
            self.assertNotIn('recovery_directory', receipt)

    def test_active_process_keeps_recovery_copy_and_does_not_replace_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            coverage, product, backup = self.transaction(Path(directory))
            with patch.object(runtime_coverage, 'stop_owned'), \
                    patch.object(runtime_coverage, 'require_idle', side_effect=RuntimeError('still active')):
                with self.assertRaisesRegex(RuntimeError, 'still active'):
                    coverage.finish(False)
            self.assertEqual(product.read_text(), 'instrumented')
            self.assertEqual((backup / 'container').read_text(), 'original')
            receipt = json.loads((coverage.evidence / 'coverage.json').read_text())
            self.assertFalse(receipt['restored'])
            self.assertEqual(receipt['recovery_directory'], str(backup.parent))

    def test_cli_profile_override_does_not_leak_bazel_test_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(__file__).with_name('integration_cli.py')
            process = subprocess.run([sys.executable, str(wrapper), '-c',
                                      'import os; print(os.environ["LLVM_PROFILE_FILE"])'],
                                     env=dict(os.environ, CLITEST_REAL_CLI=sys.executable,
                                              CLITEST_PROCESS_DIRECTORY=directory,
                                              LLVM_PROFILE_FILE='test-runner.profraw',
                                              CLITEST_RUNTIME_PROFILE='runtime-%p.profraw'),
                                     check=True, capture_output=True, text=True, timeout=10)
            self.assertEqual(process.stdout.strip(), 'runtime-%p.profraw')


if __name__ == '__main__':
    unittest.main()
