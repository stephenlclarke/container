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

"""Convert LLVM LCOV output into SonarQube generic coverage XML."""

import posixpath
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def clean_relative_path(path: str) -> str | None:
    """Normalize and reject report paths that escape the checkout."""
    normalized = posixpath.normpath(path.replace("\\", "/"))
    if normalized in ("", ".", "..") or normalized.startswith("../") or normalized.startswith("/"):
        return None
    return normalized


def relative_path(path: str, root: Path) -> str | None:
    """Return a Sonar-friendly path relative to the checkout."""
    source = path.strip().replace("\\", "/")
    root_prefix = root.as_posix().rstrip("/") + "/"
    if source.startswith(root_prefix):
        source = source[len(root_prefix) :]
    elif source.startswith("/"):
        return None
    return clean_relative_path(source)


def parse_lcov(path: Path, root: Path) -> dict[str, dict[int, bool]]:
    """Parse LCOV line records."""
    files: dict[str, dict[int, bool]] = {}
    current: str | None = None
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("SF:"):
            current = relative_path(line[3:], root)
            if current is not None:
                files.setdefault(current, {})
        elif line.startswith("DA:") and current is not None:
            number, count, *_ = line[3:].split(",")
            files[current][int(number)] = int(count) > 0
        elif line == "end_of_record":
            current = None
    return files


def write_xml(files: dict[str, dict[int, bool]], output: Path) -> None:
    """Write SonarQube generic coverage XML."""
    coverage = ET.Element("coverage", version="1")
    for file_path in sorted(files):
        file_element = ET.SubElement(coverage, "file", path=file_path)
        for number in sorted(files[file_path]):
            ET.SubElement(
                file_element,
                "lineToCover",
                lineNumber=str(number),
                covered=str(files[file_path][number]).lower(),
            )
    tree = ET.ElementTree(coverage)
    ET.indent(tree, space="  ")
    tree.write(output, encoding="utf-8", xml_declaration=True)


def main() -> int:
    """Convert one project-confined LCOV report."""
    if len(sys.argv) != 3:
        print("usage: lcov-to-sonarqube-generic.py <input.lcov> <output.xml>", file=sys.stderr)
        return 2
    root = Path.cwd().resolve()
    input_path = Path(sys.argv[1]).resolve()
    output_path = Path(sys.argv[2]).resolve()
    input_path.relative_to(root)
    output_path.relative_to(root)
    write_xml(parse_lcov(input_path, root), output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
