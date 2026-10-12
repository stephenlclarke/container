#!/usr/bin/env python3
"""Focused standalone helper tests against an explicitly supplied disposable fixture."""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class CopyTests(unittest.TestCase):
    helper: Path
    fixture: Path
    fsck: Path
    debugfs: Path

    def setUp(self) -> None:
        # APFS clones require the scratch directory and immutable input on the
        # same volume; a runner's unrelated TMPDIR may live on the external SSD.
        self.temporary = tempfile.TemporaryDirectory(prefix="ext4-copy-test-", dir=self.fixture.parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.image = self.root / "staged.ext4"
        clone = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True).clonefile
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        clone.restype = ctypes.c_int
        if clone(os.fsencode(self.fixture), os.fsencode(self.image), 0):
            raise OSError(ctypes.get_errno(), "clone fixture")
        self.image.chmod(0o600)
        self.source = self.root / "payload"
        self.payload = bytes(range(256)) * 35 + b"tail"
        self.source.write_bytes(self.payload)

    def invoke(self, destination: str, *, mode: int = 0o640, uid: int = 123,
               gid: int = 456, parents: int = 1, ownership: int = 1,
               basename: str = "host-file", source: Path | None = None,
               protocol: str = "--protocol=1") -> int:
        image_fd = os.open(self.image, os.O_RDWR | os.O_NOFOLLOW)
        source_fd = os.open(source or self.source, os.O_RDONLY | os.O_NOFOLLOW)
        # Put originals above destination descriptors before setting spawn actions.
        image_copy = fcntl.fcntl(image_fd, fcntl.F_DUPFD_CLOEXEC, 10)
        source_copy = fcntl.fcntl(source_fd, fcntl.F_DUPFD_CLOEXEC, 10)
        os.close(image_fd)
        os.close(source_fd)
        try:
            actions = [(os.POSIX_SPAWN_DUP2, image_copy, 3),
                       (os.POSIX_SPAWN_DUP2, source_copy, 4),
                       (os.POSIX_SPAWN_CLOSE, image_copy),
                       (os.POSIX_SPAWN_CLOSE, source_copy)]
            pid = os.posix_spawn(str(self.helper), [str(self.helper), protocol, destination,
                                 basename, str(mode), str(uid), str(gid), str(parents),
                                 str(ownership)], {"LANG": "C", "LC_ALL": "C"}, file_actions=actions)
            _, status = os.waitpid(pid, 0)
            return os.waitstatus_to_exitcode(status)
        finally:
            os.close(image_copy)
            os.close(source_copy)

    def debug(self, command: str, *, write: bool = False) -> str:
        arguments = [str(self.debugfs)] + (["-w"] if write else [])
        return subprocess.check_output(arguments + ["-R", command, str(self.image)],
                                       stderr=subprocess.STDOUT, text=True, timeout=30)

    def check_file(self, name: str, *, payload: bytes | None = None,
                   mode: int = 0o640, uid: int = 123, gid: int = 456) -> None:
        output = self.root / "dump"
        output.unlink(missing_ok=True)
        self.debug(f'dump {name} "{output}"')
        self.assertEqual(output.read_bytes(), self.payload if payload is None else payload)
        metadata = self.debug("stat " + name)
        self.assertRegex(metadata, rf"Mode:\s+{mode:04o}\b")
        self.assertRegex(metadata, rf"User:\s+{uid}\s+Group:\s+{gid}\b")
        self.assertIn("EXTENTS:", metadata)
        check = subprocess.run([str(self.fsck), "-fn", str(self.image)],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_new_file_and_high_ownership(self) -> None:
        self.assertEqual(self.invoke("/new", uid=70001, gid=80002), 0)
        self.check_file("/new", uid=70001, gid=80002)

    def test_zero_permissions_and_empty_file(self) -> None:
        self.source.write_bytes(b"")
        self.assertEqual(self.invoke("/empty", mode=0), 0)
        self.check_file("/empty", payload=b"", mode=0)

    def test_nested_parent_creation(self) -> None:
        self.assertEqual(self.invoke("/new-parent/nested/target"), 0)
        self.check_file("/new-parent/nested/target")
        self.assertRegex(self.debug("stat /new-parent/nested"), r"Mode:\s+0755\b")

    def test_existing_directory_appends_basename(self) -> None:
        self.assertEqual(self.invoke("/", basename="appended"), 0)
        self.check_file("/appended")

    def test_overwrite_truncates_and_retains_unrequested_owner(self) -> None:
        self.assertEqual(self.invoke("/overwrite"), 0)
        self.payload = b"short"
        self.source.write_bytes(self.payload)
        self.assertEqual(self.invoke("/overwrite", ownership=0, mode=0o700), 0)
        self.check_file("/overwrite", mode=0o700)

    def test_new_file_without_ownership_uses_guest_root(self) -> None:
        self.assertEqual(self.invoke("/root-owned", ownership=0), 0)
        self.check_file("/root-owned", uid=0, gid=0)

    def test_sdk_block_unit_inode_can_be_overwritten(self) -> None:
        self.assertEqual(self.invoke("/sdk-style"), 0)
        metadata = self.debug("stat /sdk-style")
        sectors = int(re.search(r"Blockcount:\s+(\d+)", metadata).group(1))
        self.assertEqual(sectors % 8, 0)
        self.debug("set_inode_field /sdk-style flags 0xc0000", write=True)
        self.debug(f"set_inode_field /sdk-style blocks_lo {sectors // 8}", write=True)
        self.payload = b"replaced sdk file"
        self.source.write_bytes(self.payload)
        self.assertEqual(self.invoke("/sdk-style"), 0)
        self.check_file("/sdk-style")

    def test_creating_entries_updates_parent_timestamps(self) -> None:
        self.debug("set_inode_field / mtime 1000000000", write=True)
        self.debug("set_inode_field / ctime 1000000000", write=True)
        self.assertEqual(self.invoke("/new"), 0)
        self.assertNotIn("0x3b9aca00", self.debug("stat /"))

    def test_missing_parent_without_creation_rejects_without_change(self) -> None:
        before = sha(self.image)
        self.assertEqual(self.invoke("/missing/target", parents=0), 3)
        self.assertEqual(sha(self.image), before)

    def test_symlink_path_rejects_without_change(self) -> None:
        self.debug("symlink /link /", write=True)
        before = sha(self.image)
        self.assertEqual(self.invoke("/link/target"), 3)
        self.assertEqual(sha(self.image), before)

    def test_dirty_filesystem_rejects_without_change(self) -> None:
        with self.image.open("r+b") as stream:
            stream.seek(1024 + 58)
            stream.write(b"\0\0")
        before = sha(self.image)
        self.assertEqual(self.invoke("/new"), 3)
        self.assertEqual(sha(self.image), before)

    def test_inline_attributes_use_guest_semantics(self) -> None:
        self.debug("ea_set / user.copy-test inline-value", write=True)
        before = sha(self.image)
        self.assertEqual(self.invoke("/new"), 3)
        self.assertEqual(sha(self.image), before)

    def test_invalid_protocol_and_component_reject(self) -> None:
        before = sha(self.image)
        self.assertEqual(self.invoke("/new", protocol="--protocol=2"), 2)
        for path in ("/../new", "/./new", "/missing/../new", ""):
            self.assertEqual(self.invoke(path), 3)
        self.assertEqual(self.invoke("/", basename="../escaped"), 3)
        self.assertEqual(sha(self.image), before)

    def test_descriptor_directory_and_shared_image_reject(self) -> None:
        before = sha(self.image)
        self.assertEqual(self.invoke("/new", source=self.root), 2)
        os.link(self.image, self.root / "alias")
        self.assertEqual(self.invoke("/new"), 2)
        self.assertEqual(sha(self.image), before)

    def test_trailing_slash_does_not_create_regular_file(self) -> None:
        before = sha(self.image)
        self.assertEqual(self.invoke("/missing/"), 3)
        self.assertEqual(sha(self.image), before)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("helper", "fixture", "fsck", "debugfs"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    for name in ("helper", "fixture", "fsck", "debugfs"):
        setattr(CopyTests, name, getattr(args, name).resolve())
    original = sha(CopyTests.fixture)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CopyTests))
    if sha(CopyTests.fixture) != original:
        raise RuntimeError("Read-only input fixture changed")
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
