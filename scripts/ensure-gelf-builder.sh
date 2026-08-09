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

if (($# == 1)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    printf 'Usage: %s\n' "$(basename "${BASH_SOURCE[0]}")"
    printf '%s\n' 'Prepare the local Linux/arm64 GELF TCP service builder.'
    exit 0
fi

# The shared local Linux-service builder owns Docker, Colima, and Buildx
# bootstrapping. Map the GELF-specific knobs before delegating so a caller can
# select a service builder without changing the journald workload's settings.
export CONTAINER_JOURNALD_BUILDER="${CONTAINER_GELF_BUILDER:-colima}"
export CONTAINER_JOURNALD_BUILDER_CPUS="${CONTAINER_GELF_BUILDER_CPUS:-4}"
export CONTAINER_JOURNALD_BUILDER_MEMORY_GIB="${CONTAINER_GELF_BUILDER_MEMORY_GIB:-4}"

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_ROOT}/ensure-journald-builder.sh" "$@"
