"""Generate the native helper's attested constants for a Bazel Go compilation."""

import json
from pathlib import Path
import runpy
import sys


def generate(build_script: Path, output: Path) -> None:
    metadata = runpy.run_path(str(build_script))
    values = {
        "helperVersion": metadata["HELPER_VERSION"],
        "mobyCommit": metadata["MOBY_COMMIT"],
        "mobyGCPLoggingDigest": metadata["MOBY_GCP_LOGGING_SHA256"],
        "helperSourceDigest": metadata["source_digest"](),
        "oracleFixtureDigest": metadata["oracle_digest"](),
    }
    lines = ["package main", "", "func init() {"]
    lines.extend(f"\t{name} = {json.dumps(value)}" for name, value in values.items())
    output.write_text("\n".join(lines + ["}", ""]))


if __name__ == "__main__":
    generate(Path(sys.argv[1]), Path(sys.argv[2]))
