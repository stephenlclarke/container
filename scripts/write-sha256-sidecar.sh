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

if [[ "$#" -ne 1 ]]; then
    printf 'usage: %s ASSET\n' "$0" >&2
    exit 64
fi

ASSET="$1"
if [[ ! -f "${ASSET}" ]]; then
    printf 'release asset does not exist: %s\n' "${ASSET}" >&2
    exit 66
fi

ASSET_DIRECTORY="$(cd "$(dirname "${ASSET}")" && pwd)"
ASSET_NAME="$(basename "${ASSET}")"
(
    cd "${ASSET_DIRECTORY}"
    shasum -a 256 "${ASSET_NAME}" > "${ASSET_NAME}.sha256"
)
