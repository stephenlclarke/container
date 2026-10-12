#!/usr/bin/env bash
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# USAGE: test_runner.sh TEST_BINARY [ARGUMENTS...]
# Present declared runfiles with both package-relative and Bazel source paths.
set -euo pipefail
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: %s TEST_BINARY [ARGUMENTS...]\n' "$(basename "$0")"
    exit 0
fi
binary="$1"
shift
[[ "$binary" == /* ]] || binary="$PWD/$binary"
package="${TEST_TARGET#@@}"
package="${package#@}"
package="${package%%//*}"
[[ "$TEST_TARGET" == @* ]] || package=_main
workspace="$TEST_TMPDIR/source-root"
mkdir -p "$workspace"
ln -s "$TEST_SRCDIR" "$workspace/external"
if [[ -d "$TEST_SRCDIR/$package" ]]; then
    shopt -s dotglob nullglob
    for entry in "$TEST_SRCDIR/$package/"*; do
        [[ -e "$entry" ]] || continue
        name="$(basename "$entry")"
        [[ "$name" == external ]] || ln -s "$entry" "$workspace/$name"
    done
fi
# rules_swift places a standalone executable in an incomplete .xctest bundle.
# Run a private standalone copy so Security validates its actual linker signature.
mkdir -p "$TEST_TMPDIR/executable"
executable="$TEST_TMPDIR/executable/$(basename "$binary")"
cp -p "$binary" "$executable"
helper="$TEST_SRCDIR/_main/Tools/ContainerSemanticHelper/dist/container-semantic-helper"
if [[ -x "$helper" ]]; then
    export CONTAINER_SEMANTIC_HELPER_PATH="$helper"
fi
cd "$workspace"
export TMPDIR="$TEST_TMPDIR/"
# The rapid-connect stress case interferes with the TCP echo case on Darwin
# when suites overlap (reproduced in both upstream and fork). Preserve all
# assertions and each case's concurrent connections, but isolate the cases.
if [[ "$TEST_TARGET" == *//:SocketForwarderTests.rspm* ]]; then
    export CONTAINER_RUNTIME_TESTS_SERIAL=1
fi
if [[ "${COVERAGE:-0}" == 1 && -n "${TEST_BINARIES_FOR_LLVM_COV:-}" ]]; then
    set +e
    "$executable" "$@"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
        bash "$TEST_SRCDIR/_main/Tools/bazel/collect_coverage.sh" "$executable"
    fi
    exit "$status"
fi
exec "$executable" "$@"
