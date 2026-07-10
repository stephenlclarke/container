from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "update-homebrew-formula.py"
TEMPLATE = ROOT / "Formula" / "container.rb"


class UpdateHomebrewFormulaTests(unittest.TestCase):
    def test_existing_formula_is_rebuilt_from_the_maintained_template(self) -> None:
        stale_formula = TEMPLATE.read_text(encoding="utf-8").replace(
            "    working_dir var\n",
            "    keep_alive true\n    working_dir var\n",
            1,
        )

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "container.rb"
            output.write_text(stale_formula, encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--formula",
                    str(output),
                    "--template",
                    str(TEMPLATE),
                    "--formula-class",
                    "Container",
                    "--url",
                    "https://github.com/stephenlclarke/container/releases/download/homebrew-main-100-0123456789ab/container-homebrew-main-release-arm64.tar.gz",
                    "--sha256",
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    "--version",
                    "main-release.100.0123456789ab",
                    "--label",
                    "main lane",
                    "--asset",
                    "container-homebrew-main-release-arm64.tar.gz",
                ],
                check=True,
            )

            generated = output.read_text(encoding="utf-8")

        self.assertNotIn("keep_alive true", generated)
        self.assertIn("homebrew-main-100-0123456789ab", generated)
        self.assertIn('version "main-release.100.0123456789ab"', generated)


if __name__ == "__main__":
    unittest.main()
