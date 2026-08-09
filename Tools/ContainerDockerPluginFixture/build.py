#!/usr/bin/env python3
"""Build, test, install, and verify the Docker logging-plugin fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


SCHEMA_VERSION = 1
PROTOCOL_VERSION = 1
SERVICE_VERSION = "1"
PROVIDER_ID = "io.github.stephenlclarke.container.logging.fixture"
PROVIDER_VERSION = "1.0.0"
PROVIDER_GENERATION = 1
DRIVER = "container-fixture-readable"
ALIASES = ["container-fixture"]
SERVICE_PORT = 21031
PLUGIN_SOCKET = "/run/docker/plugins/container-fixture.sock"
BUILDER_IMAGE = (
    "golang:1.25.6-bookworm@sha256:"
    "f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e"
)
RUNTIME_IMAGE = (
    "debian:bookworm-slim@sha256:"
    "7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818"
)
DOCKERFILE_FRONTEND = (
    "docker/dockerfile:1.7@sha256:"
    "a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e"
)
ARCHIVE_NAME = "container-docker-logging-plugin.oci.tar"
MANIFEST_NAME = "container-docker-logging-plugin.manifest.json"
PLUGIN_NAME = "container-docker-logging-fixture"


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def fixture_root() -> Path:
    return Path(__file__).resolve().parent


def service_root() -> Path:
    return fixture_root().parent / "ContainerDockerPluginService"


def sha256_bytes(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(paths: list[Path]) -> str:
    root = repository_root()
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda candidate: candidate.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        contents = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def service_source_digest() -> str:
    root = service_root()
    sources = [root / "go.mod", root / "go.sum"]
    sources.extend(path for path in root.glob("*.go") if not path.name.endswith("_test.go"))
    return sha256_tree(sources)


def fixture_source_digest() -> str:
    root = fixture_root()
    names = [
        ".dockerignore",
        "Dockerfile",
        "build.py",
        "entrypoint.sh",
        "go.mod",
        "main.go",
        "main_test.go",
    ]
    return sha256_tree([root / name for name in names])


def configured_builder() -> str:
    builder = os.environ.get("CONTAINER_DOCKER_PLUGIN_BUILDER", "colima")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", builder):
        raise RuntimeError("invalid CONTAINER_DOCKER_PLUGIN_BUILDER")
    return builder


def checked_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["BUILDX_GIT_INFO"] = "false"
    environment["SOURCE_DATE_EPOCH"] = "0"
    environment.pop("BUILDX_BAKE_ENTITLEMENTS_FS", None)
    return environment


def safe_archive_member(member: tarfile.TarInfo) -> bool:
    path = PurePosixPath(member.name)
    return (
        not path.is_absolute()
        and bool(path.parts)
        and ".." not in path.parts
        and not member.ischr()
        and not member.isblk()
        and not member.isfifo()
    )


def archive_member(archive: tarfile.TarFile, name: str) -> bytes:
    try:
        member = archive.getmember(name)
    except KeyError as error:
        raise RuntimeError(f"OCI archive omits {name}") from error
    if not safe_archive_member(member) or not member.isfile():
        raise RuntimeError(f"unsafe OCI archive member {name!r}")
    source = archive.extractfile(member)
    if source is None:
        raise RuntimeError(f"cannot read OCI archive member {name!r}")
    return source.read()


def workload_manifest_digest(archive_path: Path) -> str:
    with tarfile.open(archive_path, mode="r") as archive:
        for member in archive.getmembers():
            if not safe_archive_member(member):
                raise RuntimeError(f"unsafe OCI archive member {member.name!r}")
        candidates: list[dict[str, object]] = []

        def walk_index(index: dict[str, object]) -> None:
            manifests = index.get("manifests", [])
            if not isinstance(manifests, list):
                raise RuntimeError("invalid OCI index manifests")
            for descriptor in manifests:
                if not isinstance(descriptor, dict):
                    raise RuntimeError("invalid OCI descriptor")
                digest = descriptor.get("digest")
                if not isinstance(digest, str) or not re.fullmatch(
                    r"sha256:[0-9a-f]{64}", digest
                ):
                    raise RuntimeError("invalid OCI descriptor digest")
                if descriptor.get("mediaType") == "application/vnd.oci.image.index.v1+json":
                    nested = archive_member(
                        archive,
                        f"blobs/sha256/{digest.removeprefix('sha256:')}",
                    )
                    if f"sha256:{sha256_bytes(nested)}" != digest:
                        raise RuntimeError("nested OCI index failed its digest check")
                    walk_index(json.loads(nested))
                    continue
                platform = descriptor.get("platform", {})
                if (
                    isinstance(platform, dict)
                    and platform.get("architecture") == "arm64"
                    and platform.get("os") == "linux"
                ):
                    candidates.append(descriptor)

        walk_index(json.loads(archive_member(archive, "index.json")))
        if len(candidates) != 1:
            raise RuntimeError("OCI archive does not contain exactly one Linux arm64 workload")
        digest = candidates[0].get("digest")
        if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise RuntimeError("invalid workload manifest digest")
        contents = archive_member(
            archive,
            f"blobs/sha256/{digest.removeprefix('sha256:')}",
        )
        if f"sha256:{sha256_bytes(contents)}" != digest:
            raise RuntimeError("workload manifest blob failed its digest check")
        return digest


def build_oci(archive: Path, metadata_path: Path) -> str:
    archive.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "docker",
        "buildx",
        "build",
        "--builder",
        configured_builder(),
        "--platform",
        "linux/arm64",
        "--provenance=mode=max",
        "--build-context",
        f"plugin_service={service_root()}",
        "--build-arg",
        f"SERVICE_SOURCE_SHA256={service_source_digest()}",
        "--build-arg",
        f"FIXTURE_SOURCE_SHA256={fixture_source_digest()}",
        "--output",
        f"type=oci,dest={archive}",
        "--metadata-file",
        str(metadata_path),
        ".",
    ]
    subprocess.run(
        command,
        cwd=fixture_root(),
        env=checked_environment(),
        check=True,
    )
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    declared_digest = metadata.get("containerimage.digest")
    if not isinstance(declared_digest, str) or not declared_digest.startswith("sha256:"):
        raise RuntimeError("BuildKit metadata omitted the OCI index digest")
    return workload_manifest_digest(archive)


def expected_manifest(archive: Path) -> dict[str, object]:
    return {
        "aliases": ALIASES,
        "architecture": "arm64",
        "driver": DRIVER,
        "ociArchiveSHA256": sha256_file(archive),
        "platform": "linux",
        "pluginSocket": PLUGIN_SOCKET,
        "protocolVersion": PROTOCOL_VERSION,
        "providerGeneration": PROVIDER_GENERATION,
        "providerID": PROVIDER_ID,
        "providerVersion": PROVIDER_VERSION,
        "readLogs": True,
        "schemaVersion": SCHEMA_VERSION,
        "servicePort": SERVICE_PORT,
        "serviceSourceSHA256": service_source_digest(),
        "serviceVersion": SERVICE_VERSION,
        "workloadManifestDigest": workload_manifest_digest(archive),
    }


def write_manifest(archive: Path, output: Path) -> None:
    contents = json.dumps(expected_manifest(archive), indent=2, sort_keys=True) + "\n"
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
    output.chmod(0o600)


def build(output_directory: Path) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        dir=output_directory,
        prefix=".docker-plugin-build-",
    ) as temporary:
        temporary_root = Path(temporary)
        archive = temporary_root / ARCHIVE_NAME
        build_oci(archive, temporary_root / "build-metadata.json")
        destination = output_directory / ARCHIVE_NAME
        os.replace(archive, destination)
        destination.chmod(0o600)
        write_manifest(destination, output_directory / MANIFEST_NAME)


def run_linux_tests() -> None:
    script = """
set -eu
files=$(gofmt -l .)
test -z "$files"
go vet -mod=readonly ./...
go test -mod=readonly -race ./...
"""
    subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--platform",
            "linux/arm64",
            "-v",
            f"{fixture_root()}:/src:ro",
            "-w",
            "/src",
            "-e",
            "GOTOOLCHAIN=local",
            "-e",
            "GOWORK=off",
            BUILDER_IMAGE,
            "bash",
            "-ceu",
            script,
        ],
        check=True,
    )


def run_tests(output_directory: Path) -> None:
    run_linux_tests()
    output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        dir=output_directory,
        prefix=".docker-plugin-test-",
    ) as temporary:
        root = Path(temporary)
        first = root / "first.tar"
        second = root / "second.tar"
        first_digest = build_oci(first, root / "first.json")
        second_digest = build_oci(second, root / "second.json")
        if first_digest != second_digest:
            raise RuntimeError("pinned builds produced different workload manifest digests")
    build(output_directory)


def verify(archive: Path, manifest_path: Path) -> None:
    actual = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = expected_manifest(archive)
    if actual != expected:
        raise RuntimeError("Docker plugin manifest does not match its OCI archive or sources")
    for path in (archive, manifest_path):
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o022:
            raise RuntimeError(f"Docker plugin asset is writable by group or other: {path}")


def install(output_directory: Path, install_root: Path) -> None:
    archive = output_directory / ARCHIVE_NAME
    manifest = output_directory / MANIFEST_NAME
    verify(archive, manifest)
    parent = install_root / "libexec" / "container-plugins"
    destination = parent / PLUGIN_NAME
    if destination.exists() or destination.is_symlink():
        raise RuntimeError(f"Docker plugin fixture is already installed: {destination}")
    parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with tempfile.TemporaryDirectory(dir=parent, prefix=f".{PLUGIN_NAME}.") as temporary:
        staging = Path(temporary)
        binary_directory = staging / "bin"
        resource_directory = staging / "resources"
        binary_directory.mkdir(mode=0o755)
        resource_directory.mkdir(mode=0o755)
        config = """abstract = "Docker logging-plugin certification fixture"
author = "container project"

[servicesConfig]
loadAtBoot = false
runAtLoad = false
defaultArguments = []

[[servicesConfig.services]]
type = "logging"
description = "Private Docker logging-plugin workload"
"""
        (staging / "config.toml").write_text(config, encoding="utf-8")
        binary = binary_directory / PLUGIN_NAME
        binary.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        shutil.copy2(archive, resource_directory / ARCHIVE_NAME)
        shutil.copy2(manifest, resource_directory / MANIFEST_NAME)
        (staging / "config.toml").chmod(0o644)
        binary.chmod(0o755)
        (resource_directory / ARCHIVE_NAME).chmod(0o600)
        (resource_directory / MANIFEST_NAME).chmod(0o600)
        os.replace(staging, destination)


def uninstall(install_root: Path) -> None:
    destination = install_root / "libexec" / "container-plugins" / PLUGIN_NAME
    if not destination.exists() and not destination.is_symlink():
        return
    if destination.is_symlink() or not destination.is_dir():
        raise RuntimeError(f"refusing to remove unexpected plugin path: {destination}")
    shutil.rmtree(destination)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "test"):
        child = subparsers.add_parser(command)
        child.add_argument(
            "--output-directory",
            type=Path,
            default=repository_root() / ".build" / "container-docker-plugin-fixture",
        )
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--archive", type=Path, required=True)
    verify_parser.add_argument("--manifest", type=Path, required=True)
    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--output-directory", type=Path, required=True)
    install_parser.add_argument("--install-root", type=Path, required=True)
    uninstall_parser = subparsers.add_parser("uninstall")
    uninstall_parser.add_argument("--install-root", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "build":
            build(arguments.output_directory.resolve())
        elif arguments.command == "test":
            run_tests(arguments.output_directory.resolve())
        elif arguments.command == "verify":
            verify(arguments.archive.resolve(), arguments.manifest.resolve())
        elif arguments.command == "install":
            install(
                arguments.output_directory.resolve(),
                arguments.install_root.resolve(),
            )
        elif arguments.command == "uninstall":
            uninstall(arguments.install_root.resolve())
        else:
            raise AssertionError(f"unhandled command: {arguments.command}")
    except (OSError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"Docker plugin fixture failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
