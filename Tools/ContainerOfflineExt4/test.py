#!/usr/bin/env python3
"""Run maintained offline-copy boundary tests with explicit independent oracles."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("helper", "fixture", "journal-fixture", "fsck", "debugfs"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    repository = root.parents[1]
    bridge = repository / "Sources/COfflineCopyProcess"
    inputs = {name: getattr(args, name.replace("-", "_")).resolve()
              for name in ("helper", "fixture", "journal-fixture", "fsck", "debugfs")}
    for name, path in inputs.items():
        if not path.is_file():
            parser.error(name + " must identify an existing regular file")
    with tempfile.TemporaryDirectory(prefix="offline-copy-tests-") as temporary:
        output = Path(temporary)
        commands = [
            [sys.executable, "-m", "unittest", "discover", "-s", str(root), "-p", "test_build.py"],
            ["/usr/bin/clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I" + str(root), str(root / "copy_sandbox.c"), str(root / "sandbox_test.c"),
             "-o", str(output / "sandbox-tests")],
            [str(output / "sandbox-tests"), str(output / "sandbox-files")],
            ["/usr/bin/clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I" + str(bridge / "include"), str(bridge / "COfflineCopyProcess.c"),
             str(root / "process_test.c"), "-o", str(output / "process-tests")],
            [str(output / "process-tests")],
            [sys.executable, str(root / "test_helper.py"),
             *[part for name, path in inputs.items() for part in ("--" + name, str(path))]],
        ]
        for command in commands:
            started = time.monotonic_ns()
            result = subprocess.run(command, cwd=repository, timeout=120, check=False)
            print(json.dumps({"command": command, "status": result.returncode,
                              "durationNs": time.monotonic_ns() - started}), flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
