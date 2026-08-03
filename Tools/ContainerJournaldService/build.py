#!/usr/bin/env python3
"""Build, test, attest, and verify the Linux journald-service workload."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid


SCHEMA_VERSION = 1
SERVICE_VERSION = "1"
PROTOCOL_VERSION = 1
GO_VERSION = "go1.25.6"
SYSTEMD_VERSION = "252.39-1~deb12u2"
DEBIAN_SNAPSHOT = "20260801T000000Z"
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
ARCHIVE_NAME = "container-journald-service.oci.tar"
MANIFEST_NAME = "container-journald-service.manifest.json"


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def service_root() -> Path:
    return Path(__file__).resolve().parent


def sha256_bytes(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(paths: list[Path], base: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda candidate: candidate.relative_to(base).as_posix()):
        relative = path.relative_to(base).as_posix().encode("utf-8")
        contents = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def production_source_digest() -> str:
    root = service_root()
    sources = [
        root / ".dockerignore",
        root / "Dockerfile",
        root / "build.py",
        root / "debian-snapshot.sources",
        root / "entrypoint.sh",
        root / "go.mod",
        root / "go.sum",
    ]
    sources.extend(path for path in root.glob("*.go") if not path.name.endswith("_test.go"))
    return sha256_tree(sources, repository_root())


def test_source_digest() -> str:
    sources = list(service_root().glob("*_test.go"))
    sources.append(service_root() / "testproxy" / "main.go")
    return sha256_tree(sources, repository_root())


def configured_builder() -> str:
    builder = os.environ.get("CONTAINER_JOURNALD_BUILDER", "colima")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", builder):
        raise RuntimeError("invalid CONTAINER_JOURNALD_BUILDER")
    return builder


def checked_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["BUILDX_GIT_INFO"] = "false"
    environment.pop("BUILDX_BAKE_ENTITLEMENTS_FS", None)
    return environment


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
        "--build-arg",
        f"SERVICE_SOURCE_SHA256={production_source_digest()}",
        "--output",
        f"type=oci,dest={archive}",
        "--metadata-file",
        str(metadata_path),
        ".",
    ]
    subprocess.run(
        command,
        cwd=service_root(),
        env=checked_environment(),
        check=True,
    )
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    declared_digest = metadata.get("containerimage.digest")
    workload_digest = workload_manifest_digest(archive)
    if not isinstance(declared_digest, str) or not declared_digest.startswith("sha256:"):
        raise RuntimeError("BuildKit metadata omitted the OCI index digest")
    return workload_digest


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
                if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
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
        contents = archive_member(archive, f"blobs/sha256/{digest.removeprefix('sha256:')}")
        if f"sha256:{sha256_bytes(contents)}" != digest:
            raise RuntimeError("workload manifest blob failed its digest check")
        return digest


def expected_manifest(archive: Path) -> dict[str, object]:
    return {
        "architecture": "arm64",
        "builderImage": BUILDER_IMAGE,
        "debianSnapshot": DEBIAN_SNAPSHOT,
        "dockerfileFrontend": DOCKERFILE_FRONTEND,
        "goVersion": GO_VERSION,
        "ociArchiveSHA256": sha256_file(archive),
        "platform": "linux",
        "protocolVersion": PROTOCOL_VERSION,
        "runtimeImage": RUNTIME_IMAGE,
        "schemaVersion": SCHEMA_VERSION,
        "serviceSourceSHA256": production_source_digest(),
        "serviceVersion": SERVICE_VERSION,
        "systemdVersion": SYSTEMD_VERSION,
        "testSourceSHA256": test_source_digest(),
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


def build(output_directory: Path) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output_directory, prefix=".journald-build-") as temporary:
        temporary_root = Path(temporary)
        archive = temporary_root / ARCHIVE_NAME
        metadata = temporary_root / "build-metadata.json"
        build_oci(archive, metadata)
        destination = output_directory / ARCHIVE_NAME
        os.replace(archive, destination)
        write_manifest(destination, output_directory / MANIFEST_NAME)


def run_linux_tests() -> None:
    script = f"""
set -eu
find /etc/apt/sources.list.d -type f -delete
cp /src/debian-snapshot.sources /etc/apt/sources.list.d/container-snapshot.sources
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
    libsystemd-dev={SYSTEMD_VERSION} systemd={SYSTEMD_VERSION} >/dev/null
format_files=$(gofmt -l .)
test -z "$format_files"
go vet -mod=readonly ./...
systemd-machine-id-setup >/dev/null 2>&1 || true
mkdir -p /run/systemd/journal /run/log/journal
/lib/systemd/systemd-journald >/tmp/journald.log 2>&1 &
journal_pid=$!
trap 'kill "$journal_pid" 2>/dev/null || true' EXIT
for attempt in 1 2 3 4 5; do
    test -S /run/systemd/journal/socket && break
    sleep 1
done
test -S /run/systemd/journal/socket
go test -mod=readonly -race -tags=integration ./...
"""
    subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--platform",
            "linux/arm64",
            "-v",
            f"{service_root()}:/src:ro",
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
    with tempfile.TemporaryDirectory(dir=output_directory, prefix=".journald-test-") as temporary:
        temporary_root = Path(temporary)
        first = temporary_root / "first.tar"
        second = temporary_root / "second.tar"
        first_digest = build_oci(first, temporary_root / "first.json")
        second_digest = build_oci(second, temporary_root / "second.json")
        if first_digest != second_digest:
            raise RuntimeError("pinned builds produced different workload manifest digests")
    build(output_directory)


def load_integration_image(tag: str) -> None:
    subprocess.run(
        [
            "docker",
            "buildx",
            "build",
            "--builder",
            configured_builder(),
            "--platform",
            "linux/arm64",
            "--provenance=mode=max",
            "--build-arg",
            f"SERVICE_SOURCE_SHA256={production_source_digest()}",
            "--load",
            "--tag",
            tag,
            ".",
        ],
        cwd=service_root(),
        env=checked_environment(),
        check=True,
    )


def run_cross_language_integration() -> None:
    suffix = uuid.uuid4().hex[:12]
    image = f"container-journald-service:integration-{suffix}"
    service_name = f"container-journald-service-{suffix}"
    proxy_name = f"container-journald-proxy-{suffix}"
    control_volume = f"container-journald-control-{suffix}"
    state_volume = f"container-journald-state-{suffix}"
    created_image = False
    try:
        load_integration_image(image)
        created_image = True
        for volume in (control_volume, state_volume):
            subprocess.run(["docker", "volume", "create", volume], check=True)
        subprocess.run(
            [
                "docker",
                "run",
                "--detach",
                "--name",
                service_name,
                "--volume",
                f"{control_volume}:/run/container-journald",
                "--volume",
                f"{state_volume}:/var/lib/container-journald-service",
                image,
                "--sandbox-generation",
                "13",
                "--listen-unix",
                "/run/container-journald/service.sock",
            ],
            check=True,
        )
        subprocess.run(
            [
                "docker",
                "run",
                "--detach",
                "--name",
                proxy_name,
                "--publish",
                "127.0.0.1::19531",
                "--volume",
                f"{control_volume}:/run/container-journald",
                "--volume",
                f"{service_root()}:/src:ro",
                BUILDER_IMAGE,
                "go",
                "run",
                "/src/testproxy/main.go",
                "--unix",
                "/run/container-journald/service.sock",
            ],
            check=True,
        )
        published = subprocess.run(
            ["docker", "port", proxy_name, "19531/tcp"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        port = int(published.rsplit(":", 1)[1])
        deadline = time.monotonic() + 10
        while True:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("cross-language integration proxy was not ready")
                time.sleep(0.05)
        environment = os.environ.copy()
        environment["CONTAINER_JOURNALD_SERVICE_TCP_PORT"] = str(port)
        local_containerization = (
            repository_root().parent / "containerization-engine-sandbox"
        )
        edited_dependency = False
        try:
            if (local_containerization / "Package.swift").is_file():
                subprocess.run(
                    [
                        "/usr/bin/swift",
                        "package",
                        "edit",
                        "containerization",
                        "--path",
                        str(local_containerization),
                    ],
                    cwd=repository_root(),
                    check=True,
                )
                edited_dependency = True
            subprocess.run(
                [
                    "/usr/bin/swift",
                    "test",
                    "--filter",
                    "JournaldServiceLinuxIntegrationTests",
                ],
                cwd=repository_root(),
                env=environment,
                check=True,
            )
        finally:
            if edited_dependency:
                subprocess.run(
                    ["/usr/bin/swift", "package", "unedit", "containerization"],
                    cwd=repository_root(),
                    check=True,
                )
    except BaseException:
        for name in (service_name, proxy_name):
            subprocess.run(["docker", "logs", name], check=False)
        raise
    finally:
        for name in (proxy_name, service_name):
            subprocess.run(
                ["docker", "container", "stop", "--time", "5", name],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["docker", "container", "remove", name],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        for volume in (control_volume, state_volume):
            subprocess.run(
                ["docker", "volume", "remove", volume],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        if created_image:
            subprocess.run(
                ["docker", "image", "remove", image],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )


def verify(archive: Path, manifest_path: Path) -> None:
    actual = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = expected_manifest(archive)
    if actual != expected:
        raise RuntimeError("journald-service manifest does not match its OCI archive or sources")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "test"):
        child = subparsers.add_parser(command)
        child.add_argument(
            "--output-directory",
            type=Path,
            default=repository_root() / ".build" / "container-journald-service",
        )
    subparsers.add_parser("integration")
    manifest_parser = subparsers.add_parser("manifest")
    manifest_parser.add_argument("--archive", type=Path, required=True)
    manifest_parser.add_argument("--output", type=Path, required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--archive", type=Path, required=True)
    verify_parser.add_argument("--manifest", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "build":
            build(arguments.output_directory.resolve())
        elif arguments.command == "test":
            run_tests(arguments.output_directory.resolve())
        elif arguments.command == "integration":
            run_cross_language_integration()
        elif arguments.command == "manifest":
            write_manifest(arguments.archive.resolve(), arguments.output.resolve())
        elif arguments.command == "verify":
            verify(arguments.archive.resolve(), arguments.manifest.resolve())
        else:
            raise AssertionError(f"unhandled command: {arguments.command}")
    except (OSError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"journald-service build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
