#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Q-native copy of the reviewed compiled Swift/C archive and overlay format.

This intentionally keeps the sealer's overlay and digest checks from Compose;
Q's source graph, producer identity, and publication policy live separately.
"""
from __future__ import annotations
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

SHA = re.compile(r"[0-9a-f]{64}\Z")
GROUPS = ("argument-parser", "foundation", "containerization", "engine-api")
IMPLEMENTATION_EXTENSIONS = {".swift", ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".s", ".S", ".asm"}
OUTPUT_SUFFIXES = (".swiftmodule", ".swiftdoc", ".a", ".lo")
FOUNDATION_EXECUTABLES = {"SmithyCodegenCLI.rspm.__impl"}
COMMON_EXEC_MODULES = {
    "swiftpkg_swift_log": {"Logging"},
    "swiftpkg_smithy_swift": {"Smithy", "SmithySerialization"},
}
REPOSITORY_PREFIX = "+dependencies+swiftpkg_"

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def transformed_build(original: str) -> str:
    swift = 'load("@build_bazel_rules_swift//swift:swift.bzl"'
    cc = 'load("@rules_cc//cc:defs.bzl"'
    lines = []
    for line in original.splitlines():
        if line.startswith(swift):
            line = line.replace('"swift_library", ', '').replace(', "swift_library"', '')
            line = line.replace(', "swift_library")', ')')
            line = line.replace('"swift_binary", ', '').replace(', "swift_binary"', '')
            line = line.replace(', "swift_binary")', ')')
        if line.startswith(cc):
            line = line.replace('"cc_library", ', '').replace(', "cc_library"', '')
            line = line.replace(', "cc_library")', ')')
        if line.startswith((swift, cc)) and any(rule in line for rule in
                ('"swift_library"', '"cc_library"', '"swift_binary"')):
            raise ValueError("could not replace a source compiler rule")
        if line.startswith((swift, cc)) and line.endswith('.bzl")'):
            continue
        lines.append(line)
    transformed = ('load(":prebuilt.bzl", swift_library = "foundation_swift_library", '
                   'swift_binary = "foundation_swift_binary", '
                   'cc_library = "foundation_cc_library")\n' + "\n".join(lines) + "\n")
    if re.search(r'^load\([^\n]*"(?:swift_library|swift_binary|cc_library)"',
                 transformed[transformed.index("\n") + 1:], re.M):
        raise ValueError("a generated package still loads a source compiler rule")
    return transformed


def rule_modules(build: str) -> dict[str, str]:
    modules = {}
    for block in re.findall(r"^swift_library\(\n.*?^\)\n", build, re.M | re.S):
        name = re.search(r'^    name = "([^"]+)"', block, re.M)
        module = re.search(r'^    module_name = "([^"]+)"', block, re.M)
        if name and module:
            modules[name.group(1)] = module.group(1)
    return modules


def header_only_c_targets(build: str) -> set[str]:
    targets = set()
    for block in re.findall(r"^cc_library\(\n.*?^\)\n", build, re.M | re.S):
        name = re.search(r'^    name = "([^"]+)"', block, re.M)
        if not name:
            continue
        srcs = re.search(r'^    srcs = (.*?)(?=^    [a-z_]+ = |^\)\n)', block, re.M | re.S)
        if not srcs:
            targets.add(name.group(1))
            continue
        value = srcs.group(1).strip().removesuffix(",").strip()
        if not re.fullmatch(r'\[\s*(?:"[^"]+"\s*,?\s*)*\]', value, re.S):
            continue
        paths = re.findall(r'"([^"]+)"', value)
        if all(Path(path).suffix in {".h", ".hpp", ".modulemap", ".inc", ".def"}
               for path in paths):
            targets.add(name.group(1))
    return targets


def compiled_c_header_sources(build: str, compiled: set[str]) -> dict[str, list[str]]:
    """Retain public headers originally declared in C srcs, never C implementations."""
    result = {}
    found = set()
    for block in re.findall(r"^cc_library\(\n.*?^\)\n", build, re.M | re.S):
        name = re.search(r'^    name = "([^"]+)"', block, re.M)
        if not name or name.group(1) not in compiled:
            continue
        target = name.group(1)
        found.add(target)
        srcs = re.search(r'^    srcs = (.*?)(?=^    [a-z_]+ = |^\)\n)', block, re.M | re.S)
        if srcs is None:
            result[target] = []
            continue
        value = srcs.group(1).strip().removesuffix(",").strip()
        if not re.fullmatch(r'\[\s*(?:"[^"]+"\s*,?\s*)*\]', value, re.S):
            raise ValueError(f"compiled C target has unsupported source expression: {target}")
        result[target] = [path for path in re.findall(r'"([^"]+)"', value)
                          if Path(path).suffix in {".h", ".hpp", ".inc", ".modulemap", ".def"}]
    if found != compiled:
        raise ValueError("compiled C target is absent from generated BUILD: " + ", ".join(sorted(compiled - found)))
    return result


def artifact_map(paths: list[str], execution_root: Path, output_base: Path,
                 allowed: dict[str, str]) -> tuple[dict[str, dict[str, bytes]], dict[str, dict]]:
    files: dict[str, dict[str, bytes]] = {name: {} for name in allowed}
    identities: dict[str, dict] = {name: {"swift": {}, "cc": {}, "executables": {},
                                         "configured": {}}
                                   for name in allowed}
    output_base = output_base.resolve(strict=True)
    for line in paths:
        relative = Path(line.strip())
        if not relative.parts or relative.parts[0] != "bazel-out" or ".." in relative.parts:
            continue
        marker = next((part for part in relative.parts if part.startswith(REPOSITORY_PREFIX)), None)
        if marker is None:
            continue
        repository = marker.removeprefix("+dependencies+")
        if repository not in allowed:
            continue
        name = relative.name
        if not name.endswith(OUTPUT_SUFFIXES) and name not in FOUNDATION_EXECUTABLES:
            continue
        if not (execution_root / relative).exists() and name.endswith(".swiftdoc"):
            continue
        candidate = (execution_root / relative).resolve(strict=True)
        if not candidate.is_file() or not candidate.is_relative_to(output_base):
            raise ValueError(f"configured output escaped Bazel output base: {line}")
        content = candidate.read_bytes()
        # Bazel's `.lo` output is an ar archive, but cc_import accepts only
        # `.a`/`.lib` labels. Keep its bytes and expose a conventional suffix.
        key = "binary/" + (name.removesuffix(".lo") + ".a" if name.endswith(".lo") else name)
        module = (name.removeprefix("lib").removesuffix(".rspm.__impl.a")
                  if name.endswith(".rspm.__impl.a") else
                  name.removesuffix(".swiftmodule").removesuffix(".swiftdoc"))
        common = module in COMMON_EXEC_MODULES.get(repository, set())
        variant = relative.parts[1]
        previous_variant = identities[repository]["configured"].get(key)
        existing = files[repository].get(key)
        if previous_variant is not None and previous_variant != variant:
            if not common or ('-exec-' in previous_variant) == ('-exec-' in variant):
                raise ValueError(f"one package has multiple unapproved configured variants: {repository}/{name}")
            if '-exec-' not in variant:
                continue
        if existing is not None and existing != content:
            if (not common or previous_variant is None
                    or previous_variant == variant):
                raise ValueError(f"one package has conflicting configured binary variants: {repository}/{name}")
            # Only these three modules are linked by both the macOS-12 Smithy
            # generator and macOS-15 products. The branch above selected the
            # exec variant; the imported graph must prove both consumers.
        files[repository][key] = content
        identities[repository]["configured"][key] = variant
    for repository, members in files.items():
        archives = {name.removeprefix("binary/lib").removesuffix(".a"): name for name in members
                    if name.startswith("binary/lib") and name.endswith(".a")}
        identities[repository]["cc"] = {target: archive for target, archive in archives.items()
                                         if not target.endswith(".rspm.__impl")}
        identities[repository]["swift"] = {
            target: {"archive": archive,
                     "swiftmodule": "binary/" + module + ".swiftmodule",
                     "swiftdoc": "binary/" + module + ".swiftdoc"}
            for target, archive in archives.items() if target.endswith(".rspm.__impl")
            for module in [target.removesuffix(".rspm.__impl")]
        }
        identities[repository]["executables"] = {
            name: "binary/" + name for name in FOUNDATION_EXECUTABLES
            if "binary/" + name in members
        }
    return files, identities


def source_files_used_as_headers(build: str) -> set[str]:
    paths = set()
    for value in re.findall(r"\b(?:textual_hdrs|hdrs)\s*=\s*\[(.*?)\]", build, re.S):
        paths.update(re.findall(r'"([^"]+)"', value))
    return paths


def package_files(external: Path, build: str) -> dict[str, bytes]:
    members = {}
    textual_headers = source_files_used_as_headers(build)
    source_root = external.resolve(strict=True)
    for path in sorted(external.rglob("*")):
        if path.is_dir():
            continue
        if path.is_symlink():
            resolved = path.resolve(strict=True)
            if not resolved.is_file() or not resolved.is_relative_to(source_root):
                raise ValueError(f"package metadata symlink leaves source tree: {path}")
        if not path.is_file():
            raise ValueError(f"unexpected package input type: {path}")
        relative = path.relative_to(external)
        if any(part.startswith(".git") for part in relative.parts):
            continue
        if relative.parts[0] in {".build", ".swiftpm"}:
            continue
        # Generated BUILD files can contain nonempty test-data globs even
        # when production imports replace every source compilation rule.
        # Retain those declared files so package loading stays truthful.
        if (path.suffix in IMPLEMENTATION_EXTENSIONS
                and relative.parts[0] not in {"Tests", "Benchmarks", "Examples"}
                and str(relative) not in textual_headers):
            continue
        if relative.name == "BUILD.bazel":
            continue
        members[str(relative)] = path.read_bytes()
    # rglob does not descend into a directory symlink. Generated C hdrs can
    # name its logical alias (AWS CRT's config/s2n -> ../s2n/api is one such
    # source graph). Seal only explicitly declared header paths, dereference
    # inside the verified package root, and store ordinary archive files.
    for name in sorted(textual_headers):
        relative = Path(name)
        if relative.is_absolute() or not relative.parts or '..' in relative.parts:
            raise ValueError(f"generated package names an unsafe header: {name}")
        candidate = (external / relative).resolve(strict=True)
        if not candidate.is_file() or not candidate.is_relative_to(source_root):
            raise ValueError(f"generated package header leaves source tree: {name}")
        data = candidate.read_bytes()
        if name in members and members[name] != data:
            raise ValueError(f"generated package header alias changed: {name}")
        members[name] = data
    return members


def package_overlay(repository: str, source: Path, outputs: dict[str, bytes],
                    identity: dict) -> dict[str, bytes]:
    original = (source / "BUILD.bazel").read_text()
    modules = rule_modules(original)
    for target in list(identity["swift"]):
        if target not in modules:
            identity["cc"][target] = identity["swift"].pop(target)["archive"]
    for target, artifact in identity["swift"].items():
        module = modules.get(target)
        if not module:
            raise ValueError(f"compiled Swift target absent from generated BUILD: {repository}/{target}")
        artifact["swiftmodule"] = "binary/" + module + ".swiftmodule"
        artifact["swiftdoc"] = "binary/" + module + ".swiftdoc"
        if artifact["swiftdoc"] not in outputs:
            del artifact["swiftdoc"]
        if any(member not in outputs for member in artifact.values()):
            raise ValueError(f"compiled Swift target lacks an interface/archive: {repository}/{target}")
    for target, artifact in identity["executables"].items():
        if not re.search(r'^swift_binary\(\n\s+name = "' + re.escape(target) + r'"',
                         original, re.M):
            raise ValueError(f"compiled executable absent from generated BUILD: {repository}/{target}")
        if artifact not in outputs:
            raise ValueError(f"compiled executable is absent: {repository}/{target}")
    if not identity["swift"] and not identity["cc"] and not identity["executables"]:
        raise ValueError(f"package has no compiled binary output: {repository}")
    source_files = package_files(source, original)
    c_src_headers = compiled_c_header_sources(original, set(identity["cc"]))
    # Binary members supersede any source-tree file with the same name.
    if set(source_files) & set(outputs):
        raise ValueError(f"binary output collides with package metadata: {repository}")
    prebuilt = ('load("@//Tools/bazel/artifacts:foundation_import.bzl", '
                '"import_swift_library", "import_cc_library", "import_swift_binary")\n'
                'SWIFT = ' + json.dumps(identity["swift"], sort_keys=True) + '\n'
                'C = ' + json.dumps(identity["cc"], sort_keys=True) + '\n'
                'EXECUTABLES = ' + json.dumps(identity["executables"], sort_keys=True) + '\n'
                'C_HEADER_ONLY = ' + json.dumps(sorted(header_only_c_targets(original))) + '\n'
                'C_SRC_HEADERS = ' + json.dumps(c_src_headers, sort_keys=True) + '\n'
                'def foundation_swift_library(**kwargs):\n'
                '    import_swift_library(SWIFT, **kwargs)\n'
                'def foundation_cc_library(**kwargs):\n'
                '    import_cc_library(C, C_HEADER_ONLY, C_SRC_HEADERS, **kwargs)\n'
                'def foundation_swift_binary(**kwargs):\n'
                '    import_swift_binary(EXECUTABLES, **kwargs)\n')
    return {**source_files, **outputs,
            "BUILD.bazel": transformed_build(original).encode(),
            "prebuilt.bzl": prebuilt.encode()}


def archive_bytes(members: dict[str, bytes], manifest: dict) -> bytes:
    group = manifest["group"]
    contents = {**members, group + "/layer.json":
                (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()}
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, filename="") as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for name, content in sorted(contents.items()):
                info = tarfile.TarInfo(name)
                info.size, info.mtime, info.uid, info.gid = len(content), 0, 0, 0
                info.mode = 0o755 if name.endswith('/binary/SmithyCodegenCLI.rspm.__impl') else 0o644
                tar.addfile(info, io.BytesIO(content))
    return out.getvalue()


def inspect(path: Path, expected_sha: str | None = None) -> dict:
    raw = path.read_bytes()
    archive_sha = digest(raw)
    if expected_sha and archive_sha != expected_sha:
        raise ValueError("foundational archive checksum differs from lock")
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        names = tar.getnames()
        if (len(names) != len(set(names))
                or any(not name or name.startswith('/')
                       or any(part in ('', '.', '..') for part in name.split('/'))
                       for name in names)
                or any(not m.isfile() or m.issym() or m.islnk()
                       or m.mode != (0o755 if m.name.endswith('/binary/SmithyCodegenCLI.rspm.__impl')
                                     else 0o644) for m in tar)):
            raise ValueError("foundational archive has duplicate or non-file members")
        roots = {name.split("/", 1)[0] for name in names}
        if len(roots) != 1 or not roots.issubset(GROUPS) or any(".." in Path(n).parts for n in names):
            raise ValueError("foundational archive member escapes its package")
        contents = {name: tar.extractfile(name).read() for name in names}
    group = roots.pop()
    manifest = json.loads(contents.pop(group + "/layer.json"))
    if (manifest.get("schema") != 1 or manifest.get("group") != group
            or manifest.get("profile") != "native"):
        raise ValueError("foundational archive has the wrong profile")
    if set(contents) != set(manifest.get("files", {})):
        raise ValueError("foundational archive manifest is incomplete")
    for name, sha in manifest["files"].items():
        if not SHA.fullmatch(sha) or digest(contents[name]) != sha:
            raise ValueError(f"foundational archive member changed: {name}")
    return {"archiveSHA256": archive_sha, "manifest": manifest}
