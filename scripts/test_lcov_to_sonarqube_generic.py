#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright 2026 container project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
## https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Tests for the LCOV-to-SonarQube converter."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


def load_module():
    """Load the converter despite its CLI-oriented filename."""
    path = Path(__file__).with_name("lcov-to-sonarqube-generic.py")
    spec = importlib.util.spec_from_file_location("container_lcov", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lcov = load_module()


class ConverterTests(unittest.TestCase):
    """Validate path confinement and line conversion."""

    def test_parse_lcov_omits_absolute_paths_outside_project(self) -> None:
        """Host files can never be injected into the Sonar report."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "coverage.lcov"
            report.write_text(
                f"SF:{root}/Sources/API.swift\nDA:1,1\nDA:2,0\nend_of_record\n"
                "SF:/private/outside/Secret.swift\nDA:1,1\nend_of_record\n",
                encoding="utf-8",
            )
            self.assertEqual(lcov.parse_lcov(report, root), {"Sources/API.swift": {1: True, 2: False}})

    def test_write_xml_preserves_covered_and_uncovered_lines(self) -> None:
        """Both line states are represented in generic coverage XML."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "coverage.xml"
            lcov.write_xml({"Sources/API.swift": {1: True, 2: False}}, output)
            text = output.read_text(encoding="utf-8")
            self.assertIn('lineNumber="1" covered="true"', text)
            self.assertIn('lineNumber="2" covered="false"', text)


if __name__ == "__main__":
    unittest.main()
