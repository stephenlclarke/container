#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 Apple Inc. and the container project authors.
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

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("classify-build-inputs.py")
SPEC = importlib.util.spec_from_file_location("classify_build_inputs", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
classifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(classifier)


class ClassifyBuildInputsTests(unittest.TestCase):
    def test_documentation_only_change_skips_build_and_protobuf(self) -> None:
        self.assertEqual(
            classifier.classify(["README.md", "docs/build/recovery.md"]),
            (False, False),
        )

    def test_ordinary_source_change_skips_only_protobuf(self) -> None:
        self.assertEqual(
            classifier.classify(["Sources/ContainerAPIClient/Client.swift"]),
            (True, False),
        )

    def test_proto_change_runs_protobuf(self) -> None:
        self.assertEqual(
            classifier.classify(["Sources/ContainerAPIService/service.proto"]),
            (True, True),
        )

    def test_generator_dependency_change_runs_protobuf(self) -> None:
        for path in ("Package.swift", "Package.resolved", "Protobuf.Makefile"):
            with self.subTest(path=path):
                self.assertEqual(classifier.classify([path]), (True, True))

    def test_workflow_change_runs_protobuf(self) -> None:
        self.assertEqual(
            classifier.classify([".github/workflows/common.yml"]),
            (True, True),
        )

    def test_empty_change_set_fails_safe(self) -> None:
        self.assertEqual(classifier.classify([]), (True, True))


if __name__ == "__main__":
    unittest.main()
