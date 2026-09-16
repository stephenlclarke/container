#!/usr/bin/env python3
"""Tests for verified dSYM packaging."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


MODULE_PATH = Path(__file__).with_name("package.py")
SPEC = importlib.util.spec_from_file_location("debug_symbol_package", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


UUID = "8272D666-4F18-3497-93D6-E8774389D27A"


def uuid_result(path: Path, uuid: str = UUID) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(
        ["dwarfdump", "--uuid", str(path)],
        0,
        stdout=f"UUID: {uuid} (arm64) {path}\n",
        stderr="",
    )


class DebugSymbolPackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.output = self.root / "bundle" / "container-dSYM"
        self.archive = self.root / "bundle" / "container-dSYM.zip"
        self.build.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def binary(self, name: str = "container") -> Path:
        path = self.build / name
        path.write_bytes(b"mach-o")
        return path

    def sidecar(self, name: str = "container") -> Path:
        bundle = self.build / f"{name}.dSYM"
        dwarf = bundle / "Contents" / "Resources" / "DWARF"
        dwarf.mkdir(parents=True)
        (dwarf / name).write_bytes(b"symbols")
        return bundle

    @mock.patch.object(package.subprocess, "run")
    def test_existing_bundle_is_copied_verified_and_archived(
        self,
        run: mock.Mock,
    ) -> None:
        binary = self.binary()
        self.sidecar()
        self.output.mkdir(parents=True)
        (self.output / "previous").write_text("replace me")
        self.archive.write_bytes(b"replace me")
        run.side_effect = lambda arguments, **_: uuid_result(Path(arguments[-1]))

        package.package_debug_symbols(
            self.build, self.output, self.archive, ["container"], "dsymutil", "dwarfdump"
        )

        self.assertTrue(
            (self.output / "container.dSYM/Contents/Resources/DWARF/container").is_file()
        )
        with zipfile.ZipFile(self.archive) as archive:
            self.assertEqual(
                archive.namelist(),
                ["container-dSYM/container.dSYM/Contents/Resources/DWARF/container"],
            )
        self.assertEqual(run.call_count, 2)
        self.assertEqual(binary.read_bytes(), b"mach-o")
        self.assertFalse((self.output / "previous").exists())

    @mock.patch.object(package.subprocess, "run")
    def test_missing_bundle_is_materialized(self, run: mock.Mock) -> None:
        self.binary()

        def execute(
            arguments: list[str],
            **_: object,
        ) -> subprocess.CompletedProcess[str]:
            if arguments[0] == "dsymutil":
                destination = Path(arguments[-1])
                destination.mkdir(parents=True)
                return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")
            return uuid_result(Path(arguments[-1]))

        run.side_effect = execute
        package.package_debug_symbols(
            self.build, self.output, self.archive, ["container"], "dsymutil", "dwarfdump"
        )

        self.assertTrue((self.output / "container.dSYM").is_dir())
        self.assertEqual(run.call_args_list[0].args[0][0], "dsymutil")

    @mock.patch.object(package.subprocess, "run")
    def test_missing_generated_bundle_fails_closed(self, run: mock.Mock) -> None:
        self.binary()
        run.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")

        with self.assertRaisesRegex(RuntimeError, "was not created"):
            package.package_debug_symbols(
                self.build, self.output, self.archive, ["container"], "dsymutil", "dwarfdump"
            )

        self.assertFalse(self.output.exists())
        self.assertFalse(self.archive.exists())

    def test_missing_binary_preserves_previous_artifacts(self) -> None:
        self.output.mkdir(parents=True)
        (self.output / "previous").write_text("complete")
        self.archive.write_bytes(b"previous archive")

        with self.assertRaisesRegex(FileNotFoundError, "required executable"):
            package.package_debug_symbols(
                self.build, self.output, self.archive, ["container"], "dsymutil", "dwarfdump"
            )

        self.assertEqual((self.output / "previous").read_text(), "complete")
        self.assertEqual(self.archive.read_bytes(), b"previous archive")

    @mock.patch.object(package.subprocess, "run")
    def test_uuid_mismatch_fails_closed(self, run: mock.Mock) -> None:
        self.binary()
        self.sidecar()
        run.side_effect = [
            uuid_result(self.build / "container"),
            uuid_result(
                self.build / "container.dSYM",
                "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            ),
        ]

        with self.assertRaisesRegex(RuntimeError, "debug UUID mismatch"):
            package.package_debug_symbols(
                self.build, self.output, self.archive, ["container"], "dsymutil", "dwarfdump"
            )

        self.assertFalse(self.output.exists())
        self.assertFalse(self.archive.exists())

    @mock.patch.object(package.subprocess, "run")
    def test_no_reported_uuid_fails_closed(self, run: mock.Mock) -> None:
        self.binary()
        self.sidecar()
        run.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")

        with self.assertRaisesRegex(RuntimeError, "no debug UUIDs"):
            package.package_debug_symbols(
                self.build, self.output, self.archive, ["container"], "dsymutil", "dwarfdump"
            )

    def test_product_names_are_safe_and_unique(self) -> None:
        for products, message in (
            ([], "at least one"),
            (["container", "container"], "unique"),
            (["../container"], "invalid product"),
        ):
            with self.subTest(products=products):
                with self.assertRaisesRegex(ValueError, message):
                    package.package_debug_symbols(
                        self.build,
                        self.output,
                        self.archive,
                        products,
                        "dsymutil",
                        "dwarfdump",
                    )

        with self.assertRaisesRegex(ValueError, "share a parent"):
            package.package_debug_symbols(
                self.build,
                self.output,
                self.root / "elsewhere/container-dSYM.zip",
                ["container"],
                "dsymutil",
                "dwarfdump",
            )

    def test_publish_failure_restores_previous_artifacts(self) -> None:
        self.output.mkdir(parents=True)
        (self.output / "previous").write_text("complete")
        self.archive.write_bytes(b"previous archive")
        staged_root = self.output.parent / ".staged"
        staged_directory = staged_root / "container-dSYM"
        staged_archive = staged_root / "container-dSYM.zip"
        staged_directory.mkdir(parents=True)
        (staged_directory / "new").write_text("new")
        staged_archive.write_bytes(b"new archive")

        real_replace = package.os.replace
        calls = 0

        def fail_final_publish(source: Path, destination: Path) -> None:
            nonlocal calls
            calls += 1
            if calls == 4:
                raise OSError("simulated archive publish failure")
            real_replace(source, destination)

        with mock.patch.object(package.os, "replace", side_effect=fail_final_publish):
            with self.assertRaisesRegex(OSError, "simulated archive"):
                package.publish_artifacts(
                    staged_directory,
                    staged_archive,
                    self.output,
                    self.archive,
                )

        self.assertEqual((self.output / "previous").read_text(), "complete")
        self.assertEqual(self.archive.read_bytes(), b"previous archive")

    def test_publish_backup_failure_preserves_previous_artifacts(self) -> None:
        self.output.mkdir(parents=True)
        (self.output / "previous").write_text("complete")
        self.archive.write_bytes(b"previous archive")
        staged_root = self.output.parent / ".staged"
        staged_directory = staged_root / "container-dSYM"
        staged_archive = staged_root / "container-dSYM.zip"
        staged_directory.mkdir(parents=True)
        staged_archive.write_bytes(b"new archive")

        with mock.patch.object(
            package.os,
            "replace",
            side_effect=OSError("simulated backup failure"),
        ):
            with self.assertRaisesRegex(OSError, "simulated backup"):
                package.publish_artifacts(
                    staged_directory,
                    staged_archive,
                    self.output,
                    self.archive,
                )

        self.assertEqual((self.output / "previous").read_text(), "complete")
        self.assertEqual(self.archive.read_bytes(), b"previous archive")

    @mock.patch.object(package.subprocess, "run")
    def test_command_path_requires_a_result(self, run: mock.Mock) -> None:
        run.return_value = subprocess.CompletedProcess([], 0, stdout="\n", stderr="")
        with self.assertRaisesRegex(RuntimeError, "did not resolve"):
            package.command_path("dsymutil")

        run.return_value = subprocess.CompletedProcess(
            [], 0, stdout="/usr/bin/dsymutil\n", stderr=""
        )
        self.assertEqual(package.command_path("dsymutil"), "/usr/bin/dsymutil")

    @mock.patch.object(package, "package_debug_symbols")
    @mock.patch.object(package, "command_path")
    def test_main_parses_and_dispatches(
        self,
        command_path: mock.Mock,
        package_symbols: mock.Mock,
    ) -> None:
        command_path.side_effect = ["/toolchain/dsymutil", "/toolchain/dwarfdump"]

        package.main(
            [
                "--build-directory",
                str(self.build),
                "--output-directory",
                str(self.output),
                "--archive",
                str(self.archive),
                "--product",
                "container",
            ]
        )

        package_symbols.assert_called_once_with(
            self.build,
            self.output,
            self.archive,
            ["container"],
            "/toolchain/dsymutil",
            "/toolchain/dwarfdump",
        )


if __name__ == "__main__":
    unittest.main()
