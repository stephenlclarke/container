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

set -euo pipefail

readonly package_file="${1:-Package.swift}"

read_default() {
  local name="$1"

  sed -nE \
    "s@^let ${name} = .* \?\? \"([^\"]+)\"@\\1@p" \
    "$package_file"
}

repository="$(read_default builderShimRepository)"
digest="$(read_default builderShimDigest)"
[[ "$repository" == ghcr.io/* ]] || {
  printf 'builder shim repository is not a GHCR reference: %s\n' "$repository" >&2
  exit 1
}
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  printf 'builder shim digest is not immutable: %s\n' "$digest" >&2
  exit 1
}

help_output="$(docker run --rm --platform linux/arm64 "$repository@$digest" --help)"
for option in dns-nameserver dns-option dns-search-domain; do
  grep -Fq -- "--$option" <<<"$help_output" || {
    printf 'builder shim does not accept --%s\n' "$option" >&2
    exit 1
  }
done

printf 'builder shim contract validated: %s@%s\n' "$repository" "$digest"
