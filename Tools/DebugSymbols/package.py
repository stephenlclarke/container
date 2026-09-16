#!/usr/bin/env python3
"""Create a verified debug-symbol bundle from SwiftPM products."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile


UUID_PATTERN = re.compile(r"^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", re.MULTILINE)


def debug_uuids(path: Path, dwarfdump: str) -> set[tuple[str, str]]:
    """Return the UUID and architecture pairs reported for a Mach-O artifact."""
    result = subprocess.run(
        [dwarfdump, "--uuid", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    uuids = {
        (match.group(1).upper(), match.group(2))
        for match in UUID_PATTERN.finditer(result.stdout)
    }
    if not uuids:
        raise RuntimeError(f"no debug UUIDs found in {path}")
    return uuids


def validate_product_name(product: str) -> None:
    """Reject names that could escape the selected SwiftPM build directory."""
    if not product or Path(product).name != product or product in {".", ".."}:
        raise ValueError(f"invalid product name: {product!r}")


def prepare_bundle(
    binary: Path,
    destination: Path,
    dsymutil: str,
    dwarfdump: str,
) -> None:
    """Copy or materialize one dSYM, then verify it belongs to the binary."""
    if not binary.is_file():
        raise FileNotFoundError(f"required executable is missing: {binary}")

    source_bundle = binary.with_name(f"{binary.name}.dSYM")
    if source_bundle.is_dir():
        shutil.copytree(source_bundle, destination)
    else:
        subprocess.run(
            [dsymutil, str(binary), "-o", str(destination)],
            check=True,
        )

    if not destination.is_dir():
        raise RuntimeError(f"debug symbol bundle was not created: {destination}")
    binary_uuids = debug_uuids(binary, dwarfdump)
    bundle_uuids = debug_uuids(destination, dwarfdump)
    if binary_uuids != bundle_uuids:
        raise RuntimeError(
            f"debug UUID mismatch for {binary.name}: "
            f"binary={sorted(binary_uuids)}, bundle={sorted(bundle_uuids)}"
        )


def write_archive(source: Path, destination: Path) -> None:
    """Write a stable-path zip archive in the caller's staging directory."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        destination,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
    ) as zip_file:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                zip_file.write(path, Path(source.name) / path.relative_to(source))


def publish_artifacts(
    staged_directory: Path,
    staged_archive: Path,
    output_directory: Path,
    archive: Path,
) -> None:
    """Publish both artifacts together and restore prior artifacts on failure."""
    backup_directory = staged_directory.parent / ".previous-dSYM"
    backup_archive = staged_directory.parent / ".previous-dSYM.zip"
    had_directory = output_directory.exists()
    had_archive = archive.exists()
    directory_backed_up = False
    archive_backed_up = False
    directory_published = False
    archive_published = False
    try:
        if had_directory:
            os.replace(output_directory, backup_directory)
            directory_backed_up = True
        if had_archive:
            os.replace(archive, backup_archive)
            archive_backed_up = True
        os.replace(staged_directory, output_directory)
        directory_published = True
        os.replace(staged_archive, archive)
        archive_published = True
    except BaseException:
        if directory_published and output_directory.exists():
            shutil.rmtree(output_directory)
        if archive_published:
            archive.unlink(missing_ok=True)
        if directory_backed_up and backup_directory.exists():
            os.replace(backup_directory, output_directory)
        if archive_backed_up and backup_archive.exists():
            os.replace(backup_archive, archive)
        raise


def package_debug_symbols(
    build_directory: Path,
    output_directory: Path,
    archive: Path,
    products: list[str],
    dsymutil: str,
    dwarfdump: str,
) -> None:
    """Prepare all requested bundles and publish the directory and archive."""
    if not products:
        raise ValueError("at least one product is required")
    if len(set(products)) != len(products):
        raise ValueError("product names must be unique")
    if output_directory.parent != archive.parent:
        raise ValueError("debug symbol directory and archive must share a parent")
    for product in products:
        validate_product_name(product)

    output_directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        dir=output_directory.parent,
        prefix=f".{output_directory.name}.",
    ) as temporary_parent:
        staged_output = Path(temporary_parent) / output_directory.name
        staged_archive = Path(temporary_parent) / archive.name
        staged_output.mkdir()
        for product in products:
            prepare_bundle(
                build_directory / product,
                staged_output / f"{product}.dSYM",
                dsymutil,
                dwarfdump,
            )
        write_archive(staged_output, staged_archive)
        publish_artifacts(
            staged_output,
            staged_archive,
            output_directory,
            archive,
        )


def command_path(command: str) -> str:
    """Resolve an Apple developer tool from the active Xcode toolchain."""
    result = subprocess.run(
        ["xcrun", "--find", command],
        check=True,
        capture_output=True,
        text=True,
    )
    path = result.stdout.strip()
    if not path:
        raise RuntimeError(f"xcrun did not resolve {command}")
    return path


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-directory", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--product", action="append", default=[])
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    options = arguments(argv)
    package_debug_symbols(
        options.build_directory,
        options.output_directory,
        options.archive,
        options.product,
        command_path("dsymutil"),
        command_path("dwarfdump"),
    )


if __name__ == "__main__":
    main()
