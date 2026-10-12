#!/usr/bin/env python3
"""Build the standalone EXT4 helper from authenticated, bundled upstream sources."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "1.47.4"
ARCHIVE_NAME = f"e2fsprogs-{VERSION}.tar.gz"
SOURCE_URL = (
    "https://downloads.sourceforge.net/project/e2fsprogs/e2fsprogs/"
    f"v{VERSION}/{ARCHIVE_NAME}"
)
SOURCE_SHA256 = "2cec05f39c20ee621f14926195664e66e6017190ac8e4bbdb16d86082e43c5da"
BINARY = "container-ext4-copy"
MANIFEST = BINARY + ".manifest.json"
CORRESPONDING_SOURCE = BINARY + ".source.tar.gz"
CONFIGURE = [
    "--disable-nls", "--disable-debugfs", "--disable-imager", "--disable-resizer",
    "--disable-testio-debug", "--disable-tdb", "--enable-libuuid", "--enable-libblkid",
    "--disable-fsck", "--disable-e2initrd-helper", "--disable-uuidd",
    "--disable-elf-shlibs", "--disable-bsd-shlibs", "--disable-profile",
]


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def authenticate(path: Path) -> None:
    if path.is_symlink() or not path.is_file() or digest(path) != SOURCE_SHA256:
        raise RuntimeError("e2fsprogs source archive does not match its pinned SHA-256")


def obtain_archive(cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / ARCHIVE_NAME
    if target.exists() or target.is_symlink():
        authenticate(target)
        return target
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as temporary:
        incoming = Path(temporary.name)
        try:
            with urllib.request.urlopen(SOURCE_URL, timeout=60) as response:
                shutil.copyfileobj(response, temporary)
            temporary.flush()
            authenticate(incoming)
            os.replace(incoming, target)
        finally:
            incoming.unlink(missing_ok=True)
    return target


def extract(archive_path: Path, destination: Path) -> Path:
    """Extract only regular upstream sources; preserve the full original archive."""
    authenticate(archive_path)
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        seen: set[str] = set()
        for member in members:
            name = PurePosixPath(member.name)
            if (name.is_absolute() or ".." in name.parts or not name.parts or
                    name.parts[0] != f"e2fsprogs-{VERSION}" or member.name in seen):
                raise RuntimeError("Unsafe or duplicate source archive member")
            seen.add(member.name)
            if member.issym() and member.name == f"e2fsprogs-{VERSION}/RELEASE-NOTES":
                if member.linkname != "doc/RelNotes/v1.47.3.txt":
                    raise RuntimeError("Unexpected documentation symlink")
                continue
            if not member.isdir() and not member.isfile():
                raise RuntimeError("Non-regular source archive member")
        for member in members:
            if member.issym():
                continue
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
    return destination / f"e2fsprogs-{VERSION}"


def environment() -> dict[str, str]:
    # An allowlist prevents configure from discovering optional Homebrew inputs.
    result = {key: os.environ[key] for key in ("HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT")
              if key in os.environ}
    result.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                   "CC": "/usr/bin/clang", "CFLAGS": "-O2 -fPIC -mmacosx-version-min=15.0",
                   "MACOSX_DEPLOYMENT_TARGET": "15.0"})
    return result


def source_files() -> list[Path]:
    root = Path(__file__).resolve().parent
    return [root / name for name in ("copy.c", "copy_sandbox.c", "copy_sandbox.h", "build.py", "BUILD.bazel", "README.md")]


def toolchain(environment: dict[str, str]) -> dict[str, str]:
    sdk = environment.get("SDKROOT") or subprocess.check_output(
        ["/usr/bin/xcrun", "--show-sdk-path"], env=environment, text=True).strip()
    return {"compiler": subprocess.check_output(["/usr/bin/clang", "--version"], env=environment, text=True),
            "sdk": sdk, "sdkSettingsSHA256": digest(Path(sdk) / "SDKSettings.json"),
            "architecture": platform.machine(), "deploymentTarget": environment["MACOSX_DEPLOYMENT_TARGET"]}


def source_bundle(archive: Path, output: Path) -> None:
    """Retain complete original sources/notices and the exact helper build recipe."""
    with output.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as bundle:
            entries = [(ARCHIVE_NAME, archive.read_bytes())]
            entries += [("helper/" + path.name, path.read_bytes()) for path in source_files()]
            for name, data in entries:
                item = tarfile.TarInfo(name)
                item.size, item.mode, item.mtime = len(data), 0o644, 0
                bundle.addfile(item, io.BytesIO(data))


def update_manifest(binary: Path, sources: Path, manifest: Path) -> None:
    data = json.loads(manifest.read_text())
    if data.get("sourceSHA256") != SOURCE_SHA256 or data.get("protocol") != 1:
        raise RuntimeError("Unexpected helper build manifest")
    if digest(sources) != data["correspondingSourceSHA256"]:
        raise RuntimeError("Corresponding source bundle changed")
    data["binarySHA256"] = digest(binary)
    manifest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def verify(binary: Path, sources: Path, manifest: Path) -> None:
    data = json.loads(manifest.read_text())
    if (data.get("sourceSHA256") != SOURCE_SHA256 or data.get("protocol") != 1 or
            digest(binary) != data.get("binarySHA256") or
            digest(sources) != data.get("correspondingSourceSHA256")):
        raise RuntimeError("Helper binary/source manifest mismatch")
    dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
    libraries = [line.strip().split(" (")[0] for line in dependencies.splitlines()[1:]]
    if libraries != ["/usr/lib/libSystem.B.dylib"]:
        raise RuntimeError("Helper has an unexpected dynamic-library dependency")


def build(archive: Path, output: Path) -> None:
    authenticate(archive)
    output.mkdir(parents=True, exist_ok=True)
    env = environment()
    root = Path(__file__).resolve().parent
    tools = toolchain(env)
    manifest_path = output / MANIFEST
    if manifest_path.is_file():
        previous = json.loads(manifest_path.read_text())
        if (previous.get("helperSources") == {path.name: digest(path) for path in source_files()}
                and previous.get("toolchain") == tools):
            verify(output / BINARY, output / CORRESPONDING_SOURCE, manifest_path)
            return
    commands: list[dict[str, object]] = []
    # Upstream make does not support whitespace in its source/build path.
    with tempfile.TemporaryDirectory(prefix="container-ext4-", dir="/tmp") as temporary:
        work = Path(temporary)
        source = extract(archive, work)
        native = work / "native"
        native.mkdir()

        def run(name: str, arguments: list[str]) -> None:
            log = output / (name + ".log")
            with log.open("wb") as stream:
                result = subprocess.run(arguments, cwd=native, env=env, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=300, check=False)
            commands.append({"name": name, "arguments": arguments, "status": result.returncode,
                             "logSHA256": digest(log)})
            if result.returncode:
                raise RuntimeError(f"{name} failed; see {log}")

        run("configure", [str(source / "configure")] + CONFIGURE)
        run("libraries", ["/usr/bin/make", "-j4", "libs"])
        libraries = [native / "lib/libext2fs.a", native / "lib/libcom_err.a"]
        binary = output / BINARY
        run("helper", ["/usr/bin/clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                       "-mmacosx-version-min=15.0", "-I" + str(native / "lib"),
                       "-I" + str(source / "lib"), "-I" + str(source / "lib/et"),
                       str(root / "copy.c"), str(root / "copy_sandbox.c"),
                       *map(str, libraries), "-o", str(binary)])
        run("sign", ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                     "--identifier", "com.apple.container.ext4-copy", str(binary)])
        sources = output / CORRESPONDING_SOURCE
        source_bundle(archive, sources)
        manifest = output / MANIFEST
        data = {"schema": 1, "protocol": 1, "upstreamVersion": VERSION,
                "sourceURL": SOURCE_URL, "sourceSHA256": SOURCE_SHA256,
                "helperLicense": "GPL-2.0-or-later",
                "upstreamNotices": "Preserved in the complete original source archive",
                "binarySHA256": digest(binary), "correspondingSourceSHA256": digest(sources),
                "helperSources": {path.name: digest(path) for path in source_files()},
                "staticLibraries": {path.name: digest(path) for path in libraries},
                "toolchain": tools,
                "commands": commands}
        manifest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        verify(binary, sources, manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "manifest", "verify"))
    parser.add_argument("--source-archive", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if args.action == "build":
        archive = args.source_archive
        if archive is None:
            archive = obtain_archive(Path.home() / "Library/Caches/com.apple.container/ext4-sources")
        build(archive.resolve(), output)
    else:
        operation = update_manifest if args.action == "manifest" else verify
        operation(output / BINARY, output / CORRESPONDING_SOURCE, output / MANIFEST)


if __name__ == "__main__":
    main()
