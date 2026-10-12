#!/usr/bin/env python3
"""Deterministic source-authentication and build-cache boundary tests."""
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import build


class BuildTests(unittest.TestCase):
    def test_source_pin_rejects_changed_bytes_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "archive"
            source.write_bytes(b"wrong source")
            with self.assertRaisesRegex(RuntimeError, "pinned SHA"):
                build.authenticate(source)
            link = Path(directory) / "link"
            link.symlink_to(source)
            with self.assertRaisesRegex(RuntimeError, "pinned SHA"):
                build.authenticate(link)

    def test_extraction_rejects_escaping_special_and_duplicate_members(self):
        for names in (["../escape"], ["/escape"], ["other/file"],
                      ["e2fsprogs-1.47.4/link"], ["e2fsprogs-1.47.4/file"] * 2):
            with self.subTest(names=names), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / "source.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    for name in names:
                        item = tarfile.TarInfo(name)
                        if name.endswith("/link"):
                            item.type, item.linkname = tarfile.SYMTYPE, "../../escape"
                        output.addfile(item)
                with patch.object(build, "authenticate"), self.assertRaises(RuntimeError):
                    build.extract(archive, root / "out")
                self.assertFalse((root / "out").exists())

    def test_only_known_documentation_link_is_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                item = tarfile.TarInfo("e2fsprogs-1.47.4/RELEASE-NOTES")
                item.type, item.linkname = tarfile.SYMTYPE, "doc/RelNotes/v1.47.3.txt"
                output.addfile(item)
                item = tarfile.TarInfo("e2fsprogs-1.47.4/source.c")
                item.size, item.mode = 4, 0o644
                output.addfile(item, io.BytesIO(b"code"))
            with patch.object(build, "authenticate"):
                source = build.extract(archive, root / "out")
            self.assertEqual((source / "source.c").read_bytes(), b"code")
            self.assertFalse((source / "RELEASE-NOTES").exists())

    def test_restricted_build_environment_drops_host_library_controls(self):
        with patch.dict(build.os.environ, {"CPATH": "/bad", "LDFLAGS": "bad", "DYLD_LIBRARY_PATH": "/bad", "PKG_CONFIG_PATH": "/bad"}):
            environment = build.environment()
        for key in ("CPATH", "LDFLAGS", "DYLD_LIBRARY_PATH", "PKG_CONFIG_PATH"):
            self.assertNotIn(key, environment)
        self.assertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertIn("--enable-libuuid", build.CONFIGURE)
        self.assertIn("--enable-libblkid", build.CONFIGURE)

    def test_resigning_updates_only_binary_hash_and_preserves_source_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary, sources, manifest = [root / name for name in ("binary", "sources", "manifest")]
            binary.write_bytes(b"resigned")
            sources.write_bytes(b"full sources")
            original = {"sourceSHA256": build.SOURCE_SHA256, "protocol": 1,
                        "correspondingSourceSHA256": build.digest(sources), "binarySHA256": "old",
                        "staticLibraries": {"library": "pinned"}}
            manifest.write_text(json.dumps(original))
            build.update_manifest(binary, sources, manifest)
            updated = json.loads(manifest.read_text())
            self.assertEqual(updated, dict(original, binarySHA256=build.digest(binary)))
            sources.write_bytes(b"substituted")
            with self.assertRaisesRegex(RuntimeError, "source bundle changed"):
                build.update_manifest(binary, sources, manifest)


if __name__ == "__main__":
    unittest.main()
