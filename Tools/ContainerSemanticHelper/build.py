#!/usr/bin/env python3
"""Build and attest the pinned Docker semantic helper."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


GO_VERSION = "go1.25.6"
GO_ARCHIVE_NAME = f"{GO_VERSION}.darwin-arm64.tar.gz"
GO_ARCHIVE_URL = f"https://go.dev/dl/{GO_ARCHIVE_NAME}"
GO_ARCHIVE_SHA256 = (
    "984521ae978a5377c7d782fd2dd953291840d7d3d0bd95781a1f32f16d94a006"
)
HELPER_VERSION = "1"
PROTOCOL_VERSION = 1
MOBY_TAG = "docker-v29.2.1"
MOBY_COMMIT = "6bc6209b88a7a834c91f77d848e025c79e0227a1"
MOBY_TEMPLATES_SHA256 = (
    "4c82c12a734e49627c745d24ef54eb658727ead67ac17253ac86f8785e746252"
)
MOBY_LOG_INFO_SHA256 = (
    "96565a4bd2db9c7021c7e4a1b16bca100d86ca5a2f892843518add0b86ec8624"
)
EXECUTABLE_NAME = "container-semantic-helper"
MANIFEST_NAME = "container-semantic-helper.manifest.json"


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def helper_root() -> Path:
    return Path(__file__).resolve().parent


def default_cache_root() -> Path:
    configured = os.environ.get("CONTAINER_SEMANTIC_HELPER_TOOLCHAIN_CACHE")
    if configured:
        return Path(configured).expanduser().resolve()
    return (
        Path.home()
        / "Library"
        / "Caches"
        / "com.apple.container"
        / "semantic-helper-toolchains"
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(paths: list[Path], base: Path) -> str:
    """Hash relative names, lengths, and bytes without archive metadata."""
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda candidate: candidate.relative_to(base).as_posix()):
        relative = path.relative_to(base).as_posix().encode("utf-8")
        contents = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def source_digest() -> str:
    root = helper_root()
    sources = [root / "go.mod", root / "build.py"]
    sources.extend(
        path
        for path in root.glob("*.go")
        if not path.name.endswith("_test.go")
    )
    return sha256_tree(sources, repository_root())


def oracle_digest() -> str:
    root = helper_root()
    sources = [root / "oracle-vectors.json"]
    sources.extend(root.glob("*_test.go"))
    return sha256_tree(sources, repository_root())


def download_archive(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=destination.parent,
        prefix=f".{destination.name}.",
        delete=False,
    ) as temporary:
        temporary_path = Path(temporary.name)
        try:
            request = urllib.request.Request(
                GO_ARCHIVE_URL,
                headers={"User-Agent": "container-semantic-helper-build/1"},
            )
            with urllib.request.urlopen(request, timeout=60) as response:
                if response.status != 200:
                    raise RuntimeError(
                        f"download {GO_ARCHIVE_URL} returned HTTP {response.status}"
                    )
                shutil.copyfileobj(response, temporary)
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise
    if sha256_file(temporary_path) != GO_ARCHIVE_SHA256:
        temporary_path.unlink(missing_ok=True)
        raise RuntimeError("downloaded Go archive failed the pinned SHA-256 check")
    os.replace(temporary_path, destination)


def validate_archive_members(archive: tarfile.TarFile) -> None:
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if (
            path.is_absolute()
            or not path.parts
            or path.parts[0] != "go"
            or ".." in path.parts
            or member.ischr()
            or member.isblk()
            or member.isfifo()
        ):
            raise RuntimeError(f"unsafe member in pinned Go archive: {member.name!r}")


def go_version(go: Path) -> str:
    result = subprocess.run(
        [str(go), "version"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def ensure_toolchain(cache_root: Path) -> Path:
    archive_path = cache_root / GO_ARCHIVE_NAME
    install_root = cache_root / GO_VERSION
    go = install_root / "go" / "bin" / "go"
    expected_version = f"go version {GO_VERSION} darwin/arm64"

    if archive_path.exists() and sha256_file(archive_path) != GO_ARCHIVE_SHA256:
        archive_path.unlink()
    if not archive_path.exists():
        download_archive(archive_path)

    if go.exists():
        try:
            if go_version(go) == expected_version:
                return go
        except (OSError, subprocess.CalledProcessError):
            pass

    cache_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        dir=cache_root,
        prefix=f".{GO_VERSION}.",
    ) as temporary:
        temporary_root = Path(temporary)
        with tarfile.open(archive_path, mode="r:gz") as archive:
            validate_archive_members(archive)
            archive.extractall(temporary_root, filter="data")
        extracted_go = temporary_root / "go" / "bin" / "go"
        if go_version(extracted_go) != expected_version:
            raise RuntimeError("extracted Go toolchain has unexpected provenance")
        if install_root.exists():
            shutil.rmtree(install_root)
        os.replace(temporary_root, install_root)
    return go


def go_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "CGO_ENABLED": "0",
            "GOARCH": "arm64",
            "GOENV": "off",
            "GOOS": "darwin",
            "GOPROXY": "off",
            "GOTOOLCHAIN": "local",
            "GOWORK": "off",
        }
    )
    environment.pop("GOFLAGS", None)
    return environment


def build_arguments(go: Path, output: Path) -> list[str]:
    linker_flags = " ".join(
        [
            "-buildid=",
            f"-X main.helperVersion={HELPER_VERSION}",
            f"-X main.mobyCommit={MOBY_COMMIT}",
            f"-X main.helperSourceDigest={source_digest()}",
            f"-X main.oracleFixtureDigest={oracle_digest()}",
        ]
    )
    return [
        str(go),
        "build",
        "-mod=readonly",
        "-trimpath",
        "-buildvcs=false",
        f"-ldflags={linker_flags}",
        "-o",
        str(output),
        ".",
    ]


def build_unsigned(go: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        build_arguments(go, output),
        cwd=helper_root(),
        env=go_environment(),
        check=True,
    )


def sign_ad_hoc(binary: Path) -> None:
    subprocess.run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--identifier",
            "com.apple.container.semantic-helper",
            str(binary),
        ],
        check=True,
    )


def manifest(binary: Path) -> dict[str, object]:
    return {
        "architecture": "arm64",
        "binarySHA256": sha256_file(binary),
        "goArchiveSHA256": GO_ARCHIVE_SHA256,
        "goVersion": GO_VERSION,
        "helperSourceSHA256": source_digest(),
        "helperVersion": HELPER_VERSION,
        "mobyCommit": MOBY_COMMIT,
        "mobyLogInfoSHA256": MOBY_LOG_INFO_SHA256,
        "mobyTag": MOBY_TAG,
        "mobyTemplatesSHA256": MOBY_TEMPLATES_SHA256,
        "oracleFixtureSHA256": oracle_digest(),
        "protocolVersion": PROTOCOL_VERSION,
        "schemaVersion": 1,
    }


def write_manifest(binary: Path, output: Path) -> None:
    contents = json.dumps(manifest(binary), indent=2, sort_keys=True) + "\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output.parent,
        prefix=f".{output.name}.",
        delete=False,
    ) as temporary:
        temporary.write(contents)
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, output)


def build(output_directory: Path, cache_root: Path) -> None:
    go = ensure_toolchain(cache_root)
    output_directory.mkdir(parents=True, exist_ok=True)
    executable = output_directory / EXECUTABLE_NAME
    with tempfile.NamedTemporaryFile(
        dir=output_directory,
        prefix=f".{EXECUTABLE_NAME}.",
        delete=False,
    ) as temporary:
        temporary_path = Path(temporary.name)
    temporary_path.unlink()
    try:
        build_unsigned(go, temporary_path)
        sign_ad_hoc(temporary_path)
        os.replace(temporary_path, executable)
    finally:
        temporary_path.unlink(missing_ok=True)
    write_manifest(executable, output_directory / MANIFEST_NAME)


def run_tests(output_directory: Path, cache_root: Path) -> None:
    go = ensure_toolchain(cache_root)
    go_files = sorted(helper_root().glob("*.go"))
    formatting = subprocess.run(
        [str(go.parent / "gofmt"), "-l", *map(str, go_files)],
        check=True,
        capture_output=True,
        text=True,
    )
    if formatting.stdout:
        raise RuntimeError(f"gofmt required for:\n{formatting.stdout}")
    environment = go_environment()
    subprocess.run(
        [str(go), "vet", "-mod=readonly", "./..."],
        cwd=helper_root(),
        env=environment,
        check=True,
    )
    output_directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(go),
            "test",
            "-mod=readonly",
            "-trimpath",
            "-coverprofile",
            str(output_directory / "coverage.out"),
            "./...",
        ],
        cwd=helper_root(),
        env=environment,
        check=True,
    )
    with tempfile.TemporaryDirectory() as temporary:
        first = Path(temporary) / "first"
        second = Path(temporary) / "second"
        build_unsigned(go, first)
        build_unsigned(go, second)
        if sha256_file(first) != sha256_file(second):
            raise RuntimeError("pinned semantic-helper build is not reproducible")
    build(output_directory, cache_root)


def verify(binary: Path, manifest_path: Path) -> None:
    actual = json.loads(manifest_path.read_text(encoding="utf-8"))
    if actual != manifest(binary):
        raise RuntimeError("semantic-helper manifest does not match its binary or sources")
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", str(binary)],
        check=True,
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cache-root",
        type=Path,
        default=default_cache_root(),
        help="verified pinned Go toolchain cache",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    for command in ("build", "test"):
        child = subparsers.add_parser(command)
        child.add_argument(
            "--output-directory",
            type=Path,
            default=repository_root() / ".build" / "container-semantic-helper",
        )

    manifest_parser = subparsers.add_parser("manifest")
    manifest_parser.add_argument("--binary", type=Path, required=True)
    manifest_parser.add_argument("--output", type=Path, required=True)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--binary", type=Path, required=True)
    verify_parser.add_argument("--manifest", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "build":
            build(arguments.output_directory.resolve(), arguments.cache_root.resolve())
        elif arguments.command == "test":
            run_tests(
                arguments.output_directory.resolve(),
                arguments.cache_root.resolve(),
            )
        elif arguments.command == "manifest":
            write_manifest(arguments.binary.resolve(), arguments.output.resolve())
        elif arguments.command == "verify":
            verify(arguments.binary.resolve(), arguments.manifest.resolve())
        else:
            raise AssertionError(f"unhandled command: {arguments.command}")
    except (OSError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"semantic-helper build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
