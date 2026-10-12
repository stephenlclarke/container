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

# USAGE: collect_coverage.sh TEST_BINARY
# Export Swift profiles before Bazel's LCOV merger runs.
set -euo pipefail
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: %s TEST_BINARY\n' "$(basename "$0")"
    exit 0
fi
[[ "$#" == 1 && -n "${COVERAGE_DIR:-}" ]] || exit 2
shopt -s nullglob
profiles=("$COVERAGE_DIR/"*.profraw)
[[ "${#profiles[@]}" -gt 0 ]] || { printf '%s\n' 'No Swift coverage profiles were produced.' >&2; exit 1; }
# Bazel treats a .profdata in COVERAGE_DIR as an alternative report format and
# skips LCOV merging. Keep the intermediate in the test's private scratch root.
xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "$TEST_TMPDIR/swift.profdata"
xcrun llvm-cov export -format=lcov -instr-profile="$TEST_TMPDIR/swift.profdata" "$1" > "$COVERAGE_DIR/swift.dat"
grep -q '^DA:' "$COVERAGE_DIR/swift.dat" || { printf '%s\n' 'Swift coverage has no executable line records.' >&2; exit 1; }
