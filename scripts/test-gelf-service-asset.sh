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

# USAGE:
#   test-gelf-service-asset.sh --asset-directory PATH [--retain-work-root]
#
# Copies the sealed GELF TCP workload to a marker-protected /private/tmp root
# before the focused Swift acceptance test. SwiftPM may clean its own output
# trees while planning a test, so the test must never read its workload from a
# SwiftPM-managed directory.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly ROOT_MARKER_NAME=".container-gelf-service-swift-root"
readonly SWIFT_SCRATCH_MARKER_NAME=".container-gelf-service-swift-build-root"
readonly ARCHIVE_NAME="container-gelf-service.oci.tar"
readonly MANIFEST_NAME="container-gelf-service.manifest.json"

ASSET_DIRECTORY=""
RETAIN_WORK_ROOT=0
WORK_ROOT=""
SWIFT_SCRATCH_ROOT=""

# Report an invalid invocation or unsafe fixture state.
error() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

# Print the supported focused acceptance-test invocation.
usage() {
    sed -n '/^# USAGE:/,/^$/s/^# \{0,1\}//p' "$SELF_PATH"
}

# Parse the small explicit argument surface for this fixture.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --asset-directory)
                (($# >= 2)) || {
                    error "--asset-directory requires a value"
                    return 2
                }
                ASSET_DIRECTORY="$2"
                shift 2
                ;;
            --retain-work-root)
                RETAIN_WORK_ROOT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
    [[ -n "$ASSET_DIRECTORY" ]] || {
        error "--asset-directory is required"
        return 2
    }
}

# Confirm the supplied artifact is a safe regular input before copying it.
verify_input_assets() {
    ASSET_DIRECTORY="$(cd -P -- "$ASSET_DIRECTORY" && pwd)"
    local asset
    for asset in "$ARCHIVE_NAME" "$MANIFEST_NAME"; do
        [[ -f "$ASSET_DIRECTORY/$asset" && ! -L "$ASSET_DIRECTORY/$asset" ]] || {
            error "missing protected service asset: $ASSET_DIRECTORY/$asset"
            return 1
        }
    done
}

# Create a disposable root that cannot be removed unless this fixture owns it.
create_work_root() {
    WORK_ROOT="$(mktemp -d /private/tmp/container-gelf-service-swift.XXXXXX)"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
    install -m 0600 "$ASSET_DIRECTORY/$ARCHIVE_NAME" "$WORK_ROOT/$ARCHIVE_NAME"
    install -m 0600 "$ASSET_DIRECTORY/$MANIFEST_NAME" "$WORK_ROOT/$MANIFEST_NAME"
}

# Create an isolated SwiftPM build root for this exact artifact test.
create_swift_scratch_root() {
    SWIFT_SCRATCH_ROOT="$(mktemp -d /private/tmp/container-gelf-service-swift-build.XXXXXX)"
    touch "$SWIFT_SCRATCH_ROOT/$SWIFT_SCRATCH_MARKER_NAME"
}

# Run the real installed-artifact test through the normal package entry point.
run_acceptance_test() {
    CONTAINER_GELF_SERVICE_ASSET_DIRECTORY="$WORK_ROOT" \
        swift test --scratch-path "$SWIFT_SCRATCH_ROOT" --filter EngineLinuxSandboxGELFTCPServiceTests
    python3 Tools/ContainerGELFService/build.py verify \
        --archive "$WORK_ROOT/$ARCHIVE_NAME" \
        --manifest "$WORK_ROOT/$MANIFEST_NAME"
}

# Delete only the marker-protected disposable fixture root.
cleanup() {
    if ((RETAIN_WORK_ROOT == 0)) \
        && [[ "$WORK_ROOT" == /private/tmp/container-gelf-service-swift.* ]] \
        && [[ -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
    if ((RETAIN_WORK_ROOT == 0)) \
        && [[ "$SWIFT_SCRATCH_ROOT" == /private/tmp/container-gelf-service-swift-build.* ]] \
        && [[ -f "$SWIFT_SCRATCH_ROOT/$SWIFT_SCRATCH_MARKER_NAME" ]]; then
        rm -rf -- "$SWIFT_SCRATCH_ROOT"
    fi
}

main() {
    parse_args "$@"
    verify_input_assets
    create_work_root
    create_swift_scratch_root
    run_acceptance_test
    if ((RETAIN_WORK_ROOT == 1)); then
        printf 'Retained GELF TCP service acceptance root: %s\n' "$WORK_ROOT"
    fi
}

trap cleanup EXIT
main "$@"
