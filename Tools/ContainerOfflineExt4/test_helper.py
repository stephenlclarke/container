#!/usr/bin/env python3
"""Focused standalone helper tests against an explicitly supplied disposable fixture."""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import os
import re
import struct
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

    def test_startup_probe_requires_no_files_and_rejects_extra_arguments(self) -> None:
        before = self.image.stat(), self.source.stat()
        result = subprocess.run([str(self.helper), "--probe"], env={"LANG": "C", "LC_ALL": "C"},
                                capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.image.stat(), self.source.stat()), before)
        invalid = subprocess.run([str(self.helper), "--probe", "unexpected"],
                                 env={"LANG": "C", "LC_ALL": "C"}, capture_output=True, timeout=10, check=False)
        self.assertEqual(invalid.returncode, 2)

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
        self.assertIn("user.copy-test", self.debug("ea_list /"))
        before = sha(self.image)
        self.assertEqual(self.invoke("/new"), 3)
        self.assertEqual(sha(self.image), before)

    def test_sticky_directory_preserves_mode_and_allows_root_copy(self) -> None:
        self.debug("mkdir /sticky", write=True)
        self.debug("set_inode_field /sticky mode 041777", write=True)
        self.assertRegex(self.debug("stat /sticky"), r"Mode:\s+01777\b")
        self.assertEqual(self.invoke("/sticky/new"), 0)
        self.check_file("/sticky/new")
        self.assertRegex(self.debug("stat /sticky"), r"Mode:\s+01777\b")
        self.payload = b"root overwrite in sticky directory"
        self.source.write_bytes(self.payload)
        self.assertEqual(self.invoke("/sticky/new"), 0)
        self.check_file("/sticky/new")

    def test_setgid_directory_uses_guest_inheritance(self) -> None:
        self.debug("mkdir /setgid", write=True)
        self.debug("set_inode_field /setgid mode 042775", write=True)
        self.assertRegex(self.debug("stat /setgid"), r"Mode:\s+02775\b")
        before = sha(self.image)
        self.assertEqual(self.invoke("/setgid/new"), 3)
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


class JournalCopyTests(CopyTests):
    def setUp(self) -> None:
        super().setUp()
        with self.image.open("rb") as stream:
            stream.seek(1024)
            superblock = stream.read(1024)
        self.assertTrue(struct.unpack_from("<I", superblock, 92)[0] & 4)
        inode = struct.unpack_from("<I", superblock, 224)[0]
        block_size = 1024 << struct.unpack_from("<I", superblock, 24)[0]
        mapping = self.debug(f"bmap <{inode}> 0").splitlines()
        self.journal_offset = int(mapping[-1]) * block_size

    def journal_bytes(self) -> bytes:
        with self.image.open("rb") as stream:
            stream.seek(self.journal_offset)
            return stream.read(1024)

    def write_at(self, offset: int, value: bytes) -> None:
        with self.image.open("r+b") as stream:
            stream.seek(offset)
            stream.write(value)

    @staticmethod
    def checksum(superblock: bytearray) -> None:
        # Independent bitwise CRC32C oracle; no helper/libext2fs code is called.
        superblock[0xfc:0x100] = bytes(4)
        crc = 0xffffffff
        for byte in superblock:
            crc ^= byte
            for _ in range(8):
                crc = (crc >> 1) ^ (0x82f63b78 if crc & 1 else 0)
        struct.pack_into(">I", superblock, 0xfc, crc)

    def test_valid_journal_is_preserved(self) -> None:
        before = self.journal_bytes()
        self.assertEqual(self.invoke("/journal-copy"), 0)
        self.assertEqual(self.journal_bytes(), before)
        self.check_file("/journal-copy")

    def test_journal_inode_cannot_be_a_copy_destination(self) -> None:
        self.debug("link <8> /journal-alias", write=True)
        self.assertIn("Inode: 8", self.debug("stat /journal-alias"))
        before = sha(self.image)
        self.assertEqual(self.invoke("/journal-alias"), 3)
        self.assertEqual(sha(self.image), before)

    def test_standard_journal_checksums_and_features(self) -> None:
        original = self.journal_bytes()
        for compat, incompat in ((0, 1), (0, 3), (1, 1), (0, 9), (0, 17)):
            with self.subTest(compat=compat, incompat=incompat):
                header = bytearray(original)
                struct.pack_into(">II", header, 0x24, compat, incompat)
                if incompat & 0x18:
                    header[0x50] = 4
                    self.checksum(header)
                self.write_at(self.journal_offset, header)
                self.assertEqual(self.invoke("/journal-features"), 0)
                self.assertEqual(self.journal_bytes(), header)
                self.check_file("/journal-features")

    def test_malformed_or_nonempty_journal_rejects_without_change(self) -> None:
        original = self.journal_bytes()
        mutations = {
            "bad-magic": (0, 0), "unknown-version": (4, 9),
            "wrong-blocksize": (0x0c, 512), "short-journal": (0x10, 1),
            "long-journal": (0x10, 0xffffffff), "zero-first": (0x14, 0),
            "invalid-first": (0x14, 0xffffffff), "unflushed-log": (0x1c, 1),
            "aborted-log": (0x20, 5), "unknown-compatible": (0x24, 2),
            "unknown-incompatible": (0x28, 0x80000000), "fast-commit": (0x28, 0x20),
            "unknown-readonly": (0x2c, 1), "wrong-uuid": (0x30, 0),
            "shared-log": (0x40, 2), "dynamic-superblock": (0x44, 1),
            "unexpected-fast-commit-blocks": (0x54, 1), "conflicting-checksums": (0x28, 0x18),
            "missing-checksum-type": (0x28, 8),
        }
        for name, (offset, value) in mutations.items():
            with self.subTest(name=name):
                header = bytearray(original)
                struct.pack_into(">I", header, offset, value)
                self.write_at(self.journal_offset, header)
                before = sha(self.image)
                self.assertEqual(self.invoke("/new"), 3)
                self.assertEqual(sha(self.image), before)
        self.write_at(self.journal_offset, original)

    def test_corrupt_checksum_and_mixed_formats_reject_without_change(self) -> None:
        for compat, incompat, corrupt in ((0, 8, True), (1, 8, False)):
            with self.subTest(compat=compat, incompat=incompat, corrupt=corrupt):
                header = bytearray(self.journal_bytes())
                struct.pack_into(">II", header, 0x24, compat, incompat)
                header[0x50] = 4
                self.checksum(header)
                if corrupt:
                    header[0xfc] ^= 1
                self.write_at(self.journal_offset, header)
                before = sha(self.image)
                self.assertEqual(self.invoke("/new"), 3)
                self.assertEqual(sha(self.image), before)

    def test_filesystem_recovery_and_external_journal_reject_without_change(self) -> None:
        with self.image.open("rb") as stream:
            stream.seek(1024)
            original = stream.read(1024)
        mutations = ((92, 0x400), (96, 4), (96, 8), (100, 0x10000), (224, 0), (228, 1), (208, 1), (232, 11))
        for offset, value in mutations:
            with self.subTest(offset=offset, value=value):
                superblock = bytearray(original)
                if offset in (92, 96, 100):
                    value |= struct.unpack_from("<I", superblock, offset)[0]
                struct.pack_into("<I", superblock, offset, value)
                self.write_at(1024, superblock)
                before = sha(self.image)
                self.assertEqual(self.invoke("/new"), 3)
                self.assertEqual(sha(self.image), before)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("helper", "fixture", "fsck", "debugfs", "journal-fixture"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    for name in ("helper", "fixture", "fsck", "debugfs"):
        setattr(CopyTests, name, getattr(args, name).resolve())
    JournalCopyTests.fixture = args.journal_fixture.resolve()
    originals = {path: sha(path) for path in (CopyTests.fixture, JournalCopyTests.fixture)}
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                               for case in (CopyTests, JournalCopyTests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if any(sha(path) != digest for path, digest in originals.items()):
        raise RuntimeError("Read-only input fixture changed")
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
