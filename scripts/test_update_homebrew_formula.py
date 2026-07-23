from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "update-homebrew-formula.py"
TEMPLATE = ROOT / "Formula" / "container.rb"
WORKFLOW = ROOT / ".github" / "workflows" / "homebrew.yml"
PREBUILT_WORKFLOW = ROOT / ".github" / "workflows" / "prebuilt-binaries.yml"


class UpdateHomebrewFormulaTests(unittest.TestCase):
    def test_main_prebuilt_does_not_replace_the_matched_stable_formula(self) -> None:
        workflow = PREBUILT_WORKFLOW.read_text(encoding="utf-8")
        main_lane = workflow.split("            main)", 1)[1].split(
            "            release)",
            1,
        )[0]
        release_lane = workflow.split("            release)", 1)[1].split(
            "            release-*)",
            1,
        )[0]

        self.assertIn("promote_to_tap=false", main_lane)
        self.assertIn("promote_to_tap=true", release_lane)
        self.assertIn(
            "if: steps.lane.outputs.promote_to_tap == 'true'\n"
            "        id: tap-token",
            workflow,
        )

    def test_workflow_tolerates_a_retired_template_archive(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertNotIn(
            "brew audit --formula --strict --online",
            workflow,
        )
        self.assertIn(
            "id: template_archive",
            workflow,
        )
        self.assertEqual(
            workflow.count("if: steps.template_archive.outputs.available == 'true'"),
            2,
        )

    def test_formula_smoke_test_is_service_state_independent(self) -> None:
        template = TEMPLATE.read_text(encoding="utf-8")

        self.assertIn(
            'shell_output("#{bin}/container list --help")',
            template,
        )
        self.assertNotIn(
            'shell_output("#{bin}/container list 2>&1", 1)',
            template,
        )

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
