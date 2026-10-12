"""Original service recipes expose only a narrowly owned qualification container."""

import os
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from service_artifacts import SERVICES, load_service
from service_integration import cleanup


class ServiceTestOwnershipTests(unittest.TestCase):
    def test_each_original_recipe_preserves_race_checks_and_exports_owned_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in SERVICES:
                with self.subTest(service=name), patch.dict(os.environ, {
                    'CONTAINER_SERVICE_TEST_ID': 'a' * 32,
                    'CONTAINER_SERVICE_TEST_EVIDENCE': directory,
                }), patch('subprocess.run') as command:
                    load_service(name).run_linux_tests()
                    arguments = command.call_args.args[0]
                    self.assertIn('container-service-test-' + 'a' * 32, arguments)
                    self.assertIn('io.container-only.owner=container-service-test-' + 'a' * 32, arguments)
                    self.assertIn('type=bind,source=' + str(Path(directory).resolve()) + ',target=/evidence', arguments)
                    self.assertIn('-race', arguments[-1])
                    self.assertIn('SERVICE_COVERAGE', arguments[-1])
                    self.assertIn('-tags=integration' if name == 'journald' else '>= 90', arguments[-1])

    def test_invalid_owner_is_rejected_before_starting_docker(self):
        for name in SERVICES:
            with self.subTest(service=name), patch.dict(os.environ, {'CONTAINER_SERVICE_TEST_ID': 'unrelated'}), \
                    patch('subprocess.run') as command:
                with self.assertRaisesRegex(RuntimeError, 'ownership ID'):
                    load_service(name).run_linux_tests()
                command.assert_not_called()

    def test_wire_cleanup_refuses_a_replaced_unrelated_container(self):
        import subprocess
        response = subprocess.CompletedProcess([], 0, json.dumps([{'Config': {'Labels': {}}, 'Id': 'other'}]))
        with patch('service_integration.subprocess.run', return_value=response) as command:
            with self.assertRaisesRegex(RuntimeError, 'unrelated'):
                cleanup('colima', 'a' * 32)
            self.assertEqual(command.call_count, 1)


if __name__ == '__main__':
    unittest.main()
