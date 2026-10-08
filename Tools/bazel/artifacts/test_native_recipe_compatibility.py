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

"""Finite old-producer/current-consumer native recipe compatibility tests."""

from pathlib import Path
import shutil
import tempfile
import unittest

from Tools.bazel.artifacts import recipe_compatibility as compatibility


class RecipeCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        policy = self.root / 'Tools/bazel/artifacts/recipe_compatibility.py'
        policy.parent.mkdir(parents=True)
        shutil.copyfile(Path(compatibility.__file__), policy)
        self.old = dict(compatibility.OLD,
                        **{'Package.swift': 'a' * 64,
                           'MODULE.bazel': 'b' * 64,
                           'Tools/bazel/layers.bzl': 'c' * 64,
                           'Tools/bazel/compile.patch': 'd' * 64,
                           'Tools/bazel/artifacts/native_format.py': 'e' * 64,
                           'Tools/bazel/artifacts/release_asset.py': 'f' * 64})
        self.current = dict(self.old, **compatibility.NEW)

    def admit(self):
        return compatibility.admit(self.old, self.current, self.root)

    def test_exact_recipe_keeps_exact_producer_identity(self):
        result = compatibility.admit(self.old, self.old, self.root)
        self.assertEqual(result['mode'], 'exact')
        self.assertEqual(result['changedFiles'], [])
        self.assertEqual(result['producerRecipeSHA256'], result['currentRecipeSHA256'])

    def test_exact_two_file_transition_is_recorded(self):
        result = self.admit()
        self.assertEqual(result['mode'], 'known-consumer-verifier-update')
        self.assertEqual(result['changedFiles'], sorted(compatibility.OLD))
        self.assertNotEqual(result['producerRecipeSHA256'], result['currentRecipeSHA256'])
        self.assertEqual(result['policySHA256'], compatibility.digest(
            Path(compatibility.__file__).read_bytes()))

    def test_partial_reversed_or_unknown_pair_is_rejected(self):
        for before, after in ((self.old, dict(self.old, **{compatibility.CONSUMER:
                                                         compatibility.NEW[compatibility.CONSUMER]})),
                              (self.current, self.old),
                              (dict(self.old, **{compatibility.CONSUMER: '0' * 64}), self.current),
                              (self.old, dict(self.current, **{compatibility.IMPORTER: '1' * 64}))):
            with self.subTest(before=before, after=after):
                with self.assertRaisesRegex(ValueError, 'authenticated consumer update'):
                    compatibility.admit(before, after, self.root)

    def test_unrelated_build_or_exporter_change_is_rejected(self):
        for key in ('Package.swift', 'MODULE.bazel', 'Tools/bazel/layers.bzl',
                    'Tools/bazel/compile.patch', 'Tools/bazel/artifacts/native_format.py',
                    'Tools/bazel/artifacts/release_asset.py'):
            changed = dict(self.current, **{key: '0' * 64})
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'authenticated consumer update'):
                compatibility.admit(self.old, changed, self.root)

    def test_exact_host_fixture_transition_preserves_archive_recipe(self):
        for verifier_update in (False, True):
            before = dict(self.old, **{compatibility.HOST_FIXTURE: compatibility.HOST_FIXTURE_OLD})
            after = dict(self.current if verifier_update else self.old,
                         **{compatibility.HOST_FIXTURE: compatibility.HOST_FIXTURE_NEW})
            with self.subTest(verifier_update=verifier_update):
                result = compatibility.admit(before, after, self.root)
                self.assertIn('known-host-timeout-fixture-update', result['mode'])
                self.assertIn(compatibility.HOST_FIXTURE, result['changedFiles'])
                self.assertNotEqual(result['producerRecipeSHA256'], result['currentRecipeSHA256'])

    def test_host_fixture_transition_rejects_unknown_reverse_and_build_drift(self):
        before = dict(self.old, **{compatibility.HOST_FIXTURE: compatibility.HOST_FIXTURE_OLD})
        after = dict(self.current, **{compatibility.HOST_FIXTURE: compatibility.HOST_FIXTURE_NEW})
        for producer, current in (
                (before, dict(after, **{compatibility.HOST_FIXTURE: '0' * 64})),
                (after, before),
                (before, dict(after, **{'Package.swift': '0' * 64})),
                (before, dict(after, **{compatibility.IMPORTER: '0' * 64}))):
            with self.subTest(producer=producer, current=current):
                with self.assertRaisesRegex(ValueError, 'authenticated consumer update'):
                    compatibility.admit(producer, current, self.root)

    def test_inventory_and_hash_shape_drift_is_rejected(self):
        for current in (dict(self.current, extra='0' * 64),
                        {key: value for key, value in self.current.items() if key != 'MODULE.bazel'},
                        dict(self.current, **{'MODULE.bazel': 'not-a-sha'})):
            with self.subTest(current=current), self.assertRaisesRegex(ValueError, 'incomplete or malformed'):
                compatibility.admit(self.old, current, self.root)

    def test_selected_source_policy_mismatch_or_symlink_is_rejected(self):
        policy = self.root / 'Tools/bazel/artifacts/recipe_compatibility.py'
        policy.write_text(policy.read_text() + '# drift\n')
        with self.assertRaisesRegex(ValueError, 'policy differs'):
            self.admit()
        policy.unlink()
        policy.symlink_to(Path(compatibility.__file__))
        with self.assertRaisesRegex(ValueError, 'policy differs'):
            self.admit()


if __name__ == '__main__':
    unittest.main()
