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

SOURCE_DIRECTORY="${TEST_ROOT}/runner temporary directory"
DOWNLOAD_DIRECTORY="${TEST_ROOT}/download"
ASSET_NAME="container-homebrew-main-release-arm64.tar.gz"
mkdir -p "${SOURCE_DIRECTORY}" "${DOWNLOAD_DIRECTORY}"
printf 'portable release checksum\n' > "${SOURCE_DIRECTORY}/${ASSET_NAME}"

scripts/write-sha256-sidecar.sh "${SOURCE_DIRECTORY}/${ASSET_NAME}"

EXPECTED_DIGEST="$(shasum -a 256 "${SOURCE_DIRECTORY}/${ASSET_NAME}" | awk '{print $1}')"
EXPECTED_SIDECAR="${EXPECTED_DIGEST}  ${ASSET_NAME}"
ACTUAL_SIDECAR="$(cat "${SOURCE_DIRECTORY}/${ASSET_NAME}.sha256")"
if [[ "${ACTUAL_SIDECAR}" != "${EXPECTED_SIDECAR}" ]]; then
    printf 'checksum sidecar is not relocatable:\nexpected: %s\nactual:   %s\n' \
        "${EXPECTED_SIDECAR}" \
        "${ACTUAL_SIDECAR}" >&2
    exit 1
fi

cp "${SOURCE_DIRECTORY}/${ASSET_NAME}" "${DOWNLOAD_DIRECTORY}/"
cp "${SOURCE_DIRECTORY}/${ASSET_NAME}.sha256" "${DOWNLOAD_DIRECTORY}/"
(
    cd "${DOWNLOAD_DIRECTORY}"
    shasum -a 256 -c "${ASSET_NAME}.sha256"
)
