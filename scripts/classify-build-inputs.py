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

"""Classify changed paths for the Container build workflow."""

from __future__ import annotations

import argparse
import fnmatch
from pathlib import Path


NON_BUILD_PATTERNS = ("*.md", "docs/*", "Formula/*")
PROTOBUF_INPUT_PATTERNS = (
    "*.proto",
    "Protobuf.Makefile",
    "Package.swift",
    "Package.resolved",
    ".github/workflows/common.yml",
    ".github/workflows/merge-build.yml",
    ".github/workflows/pr-build.yml",
    ".github/workflows/release.yml",
    "scripts/classify-build-inputs.py",
    "scripts/test_classify_build_inputs.py",
)


def matches(path: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def classify(paths: list[str]) -> tuple[bool, bool]:
    """Return whether a heavy build and protobuf regeneration are required."""
    if not paths:
        return True, True

    heavy = any(not matches(path, NON_BUILD_PATTERNS) for path in paths)
    protobuf = any(matches(path, PROTOBUF_INPUT_PATTERNS) for path in paths)
    return heavy, protobuf


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("changed_files", type=Path)
    args = parser.parse_args()

    paths = [
        line.strip()
        for line in args.changed_files.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    heavy, protobuf = classify(paths)
    print(f"heavy={str(heavy).lower()}")
    print(f"protobuf={str(protobuf).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
