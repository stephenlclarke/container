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

    def test_current_formula_links_only_the_current_compose_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "container-current.rb"
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--formula",
                    str(output),
                    "--template",
                    str(TEMPLATE),
                    "--formula-class",
                    "ContainerCurrent",
                    "--compose-formula",
                    "container-compose-current",
                    "--url",
                    "https://example.invalid/current.tar.gz",
                    "--sha256",
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    "--version",
                    "current-release.100.0123456789ab",
                    "--label",
                    "current build",
                    "--asset",
                    "container-current-arm64.tar.gz",
                ],
                check=True,
            )

            generated = output.read_text(encoding="utf-8")

        self.assertIn("class ContainerCurrent < Formula", generated)
        self.assertIn('opt/container-compose-current/libexec/container-plugins/compose', generated)
        self.assertNotIn('opt/container-compose/libexec/container-plugins/compose', generated)

    def test_unknown_compose_formula_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "container.rb"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--formula",
                    str(output),
                    "--template",
                    str(TEMPLATE),
                    "--formula-class",
                    "Container",
                    "--compose-formula",
                    "container-compose-preview",
                    "--url",
                    "https://example.invalid/current.tar.gz",
                    "--sha256",
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    "--version",
                    "current-release.100.0123456789ab",
                    "--label",
                    "current build",
                    "--asset",
                    "container-current-arm64.tar.gz",
                ],
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("compose formula must be one of", completed.stderr)


if __name__ == "__main__":
    unittest.main()
