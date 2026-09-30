#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container project authors.
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

"""Pure-Python boundary checks for the Q native compiled package format."""

import io
from pathlib import Path
import tarfile
import tempfile
import unittest

import native_format


class NativeFormatTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='q-native-format-')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)

    def archive(self, members, group='foundation'):
        manifest = {
            'schema': 1, 'group': group, 'profile': 'native',
            'files': {name: native_format.digest(content) for name, content in members.items()},
        }
        archive = self.root / 'layer.tar.gz'
        archive.write_bytes(native_format.archive_bytes(members, manifest))
        return archive

    def test_contained_alias_directory_header_becomes_an_ordinary_archive_file(self):
        source = self.root / 'source'
        (source / 'config').mkdir(parents=True)
        (source / 's2n/api').mkdir(parents=True)
        (source / 's2n/api/crypto.h').write_bytes(b'public API\n')
        (source / 'config/s2n').symlink_to('../s2n/api', target_is_directory=True)
        build = 'cc_library(\n    name = "AWSCRT",\n    hdrs = ["config/s2n/crypto.h"],\n)\n'

        files = native_format.package_files(source, build)
        self.assertEqual(files['config/s2n/crypto.h'], b'public API\n')
        member = 'foundation/swiftpkg_aws_crt/config/s2n/crypto.h'
        archive = self.archive({member: files['config/s2n/crypto.h']})
        self.assertEqual(native_format.inspect(archive)['manifest']['files'][member],
                         native_format.digest(b'public API\n'))
        with tarfile.open(archive, 'r:gz') as sealed:
            self.assertTrue(sealed.getmember(member).isfile())
            self.assertFalse(sealed.getmember(member).issym())
            self.assertEqual(sealed.extractfile(member).read(), b'public API\n')

    def test_header_alias_escape_and_cycle_fail_before_sealing(self):
        source = self.root / 'source'
        (source / 'config').mkdir(parents=True)
        outside = self.root / 'foreign'
        outside.mkdir()
        (outside / 'crypto.h').write_bytes(b'foreign header\n')
        alias = source / 'config/s2n'
        build = 'cc_library(\n    name = "AWSCRT",\n    hdrs = ["config/s2n/crypto.h"],\n)\n'
        for destination in ('../../foreign', 's2n'):
            alias.symlink_to(destination)
            with self.subTest(destination=destination), self.assertRaises((ValueError, RuntimeError, OSError)):
                native_format.package_files(source, build)
            alias.unlink()

    def test_archive_rejects_raw_noncanonical_member_names(self):
        canonical = 'foundation/swiftpkg_example/BUILD.bazel'
        self.assertEqual(native_format.inspect(self.archive({canonical: b'filegroup(name = "x")\n'}))
                         ['manifest']['files'][canonical], native_format.digest(b'filegroup(name = "x")\n'))
        aliases = (
            'foundation/swiftpkg_example/./BUILD.bazel',
            'foundation/swiftpkg_example//BUILD.bazel',
            'foundation/swiftpkg_example/../swiftpkg_example/BUILD.bazel',
            '/foundation/swiftpkg_example/BUILD.bazel',
            'foundation/swiftpkg_example/BUILD.bazel/',
        )
        for alias in aliases:
            with self.subTest(alias=alias), self.assertRaises(ValueError):
                native_format.inspect(self.archive({canonical: b'original', alias: b'alias'}))

    def test_smithy_executable_keeps_executable_mode_and_import_metadata(self):
        source = self.root / 'swiftpkg_smithy_swift'
        source.mkdir()
        (source / 'BUILD.bazel').write_text(
            'load("@build_bazel_rules_swift//swift:swift.bzl", "swift_binary")\n'
            'swift_binary(\n'
            '    name = "SmithyCodegenCLI.rspm.__impl",\n'
            '    srcs = ["Sources/main.swift"],\n'
            ')\n')
        (source / 'Sources').mkdir()
        (source / 'Sources/main.swift').write_text('print("tool")\n')
        binary = 'binary/SmithyCodegenCLI.rspm.__impl'
        identity = {'swift': {}, 'cc': {}, 'executables': {
            'SmithyCodegenCLI.rspm.__impl': binary}}
        overlay = native_format.package_overlay(
            'swiftpkg_smithy_swift', source, {binary: b'compiled tool'}, identity)
        self.assertEqual(overlay[binary], b'compiled tool')
        self.assertNotIn('Sources/main.swift', overlay)
        self.assertIn(b'EXECUTABLES = {"SmithyCodegenCLI.rspm.__impl": '
                      b'"binary/SmithyCodegenCLI.rspm.__impl"}', overlay['prebuilt.bzl'])
        self.assertIn(b'swift_binary = "foundation_swift_binary"', overlay['BUILD.bazel'])

        prefix = 'foundation/swiftpkg_smithy_swift/'
        archive = self.archive({prefix + name: content for name, content in overlay.items()})
        self.assertEqual(native_format.inspect(archive)['manifest']['group'], 'foundation')
        with tarfile.open(archive, 'r:gz') as sealed:
            self.assertEqual(sealed.getmember(prefix + binary).mode, 0o755)
            self.assertEqual(sealed.getmember(prefix + 'prebuilt.bzl').mode, 0o644)
            items = [(item, sealed.extractfile(item).read()) for item in sealed]
        wrong_mode = self.root / 'wrong-mode.tar.gz'
        with tarfile.open(wrong_mode, 'w:gz') as changed:
            for item, content in items:
                if item.name == prefix + binary:
                    item.mode = 0o644
                changed.addfile(item, io.BytesIO(content))
        with self.assertRaises(ValueError):
            native_format.inspect(wrong_mode)

    def test_argument_parser_and_nonshared_configured_variants_are_rejected(self):
        execution = self.root / 'exec'
        allowed = {
            'swiftpkg_swift_argument_parser': 'swift-argument-parser',
            'swiftpkg_smithy_swift': 'smithy-swift',
        }

        def configured(variant, repository, name, content):
            relative = Path('bazel-out') / variant / 'bin/external' / ('+dependencies+' + repository) / name
            target = execution / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            return str(relative)

        cases = (
            ('swiftpkg_swift_argument_parser', 'libArgumentParser.rspm.__impl.a'),
            ('swiftpkg_smithy_swift', 'libUnshared.rspm.__impl.a'),
        )
        for repository, name in cases:
            ordinary = configured('darwin_arm64-opt', repository, name, b'ordinary')
            tool = configured('darwin_arm64-opt-exec-123', repository, name, b'tool')
            with self.subTest(repository=repository), self.assertRaisesRegex(ValueError, 'variant'):
                native_format.artifact_map([ordinary, tool], execution, self.root, allowed)

    def test_common_exec_variant_is_selected_without_losing_configured_identity(self):
        execution = self.root / 'exec'
        repository = 'swiftpkg_smithy_swift'
        name = 'libSmithy.rspm.__impl.a'
        paths = []
        for variant, content in (('darwin_arm64-opt-exec-123', b'build tool'),
                                 ('darwin_arm64-opt', b'host app')):
            relative = Path('bazel-out') / variant / 'bin/external' / ('+dependencies+' + repository) / name
            target = execution / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            paths.append(str(relative))
        key = 'binary/' + name
        for order in (paths, list(reversed(paths))):
            with self.subTest(order=order):
                files, identities = native_format.artifact_map(
                    order, execution, self.root, {repository: 'smithy-swift'})
                self.assertEqual(files[repository][key], b'build tool')
                self.assertEqual(identities[repository]['configured'][key], 'darwin_arm64-opt-exec-123')

        second_exec = Path('bazel-out/darwin_arm64-opt-exec-456/bin/external') / \
            ('+dependencies+' + repository) / name
        target = execution / second_exec
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b'other build tool')
        with self.assertRaisesRegex(ValueError, 'variant'):
            native_format.artifact_map(
                [paths[0], str(second_exec)], execution, self.root,
                {repository: 'smithy-swift'})

    def test_common_module_rejects_conflicting_files_within_one_configuration(self):
        execution = self.root / 'exec'
        repository = 'swiftpkg_swift_log'
        name = 'libLogging.rspm.__impl.a'
        paths = []
        for directory, content in (('first', b'first archive'),
                                   ('second', b'different archive')):
            relative = Path('bazel-out/darwin_arm64-opt/bin/external') / \
                ('+dependencies+' + repository) / directory / name
            target = execution / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            paths.append(str(relative))
        with self.assertRaisesRegex(ValueError, 'conflicting'):
            native_format.artifact_map(paths, execution, self.root, {repository: 'swift-log'})


if __name__ == '__main__':
    unittest.main()
