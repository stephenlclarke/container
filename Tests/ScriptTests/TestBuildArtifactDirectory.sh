#!/bin/bash
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

set -euo pipefail

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

MATCHED_BUILD_DIRECTORY="${TEST_ROOT}/matched-swift-build"
DRY_RUN="$(
    make -n \
        BUILD_CONFIGURATION=release \
        STAGING_DIR="${TEST_ROOT}/staging/" \
        HOMEBREW_ARCHIVE="${TEST_ROOT}/container.tar.gz" \
        SWIFT_BUILD="/bin/sh -c 'printf %s ${MATCHED_BUILD_DIRECTORY}'" \
        homebrew-package
)"

EXPECTED_APISERVER_INSTALL="install \"${MATCHED_BUILD_DIRECTORY}/container-apiserver\" \"${TEST_ROOT}/staging/bin/container-apiserver\""
if ! grep -Fq "${EXPECTED_APISERVER_INSTALL}" <<<"${DRY_RUN}"; then
    printf 'staging did not use the selected Swift build directory:\n%s\n' \
        "${DRY_RUN}" >&2
    exit 1
fi
