#!/usr/bin/env bash
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
exec "$executable" "$@"
