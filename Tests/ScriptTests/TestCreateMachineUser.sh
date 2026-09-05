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

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

ETC_ROOT="${TEST_ROOT}/etc"
HOME_ROOT="${TEST_ROOT}/home/machine-user"
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
mkdir -p "${ETC_ROOT}/skel"
printf 'image-user:x:%s:%s::/home/image-user:/bin/sh\n' "${CURRENT_UID}" "${CURRENT_GID}" > "${ETC_ROOT}/passwd"
printf 'image-group:x:%s:\n' "${CURRENT_GID}" > "${ETC_ROOT}/group"
: > "${ETC_ROOT}/shadow"

CONTAINER_ETC_ROOT="${ETC_ROOT}" \
CONTAINER_USER=machine-user \
CONTAINER_UID="${CURRENT_UID}" \
CONTAINER_GID="${CURRENT_GID}" \
CONTAINER_HOME="${HOME_ROOT}" \
CONTAINER_SHELL=/bin/sh \
    Sources/Plugins/MachineAPIServer/Resources/create-user.sh

grep -qx "machine-user:x:${CURRENT_UID}:${CURRENT_GID}::${HOME_ROOT}:/bin/sh" "${ETC_ROOT}/passwd"
grep -qx "machine-user:!:19000:0:99999:7:::" "${ETC_ROOT}/shadow"
test -f "${ETC_ROOT}/sudoers.d/machine-user"

printf 'conflict:x:4294967294:%s::/home/conflict:/bin/sh\n' "${CURRENT_GID}" >> "${ETC_ROOT}/passwd"
if CONTAINER_ETC_ROOT="${ETC_ROOT}" \
    CONTAINER_USER=conflict \
    CONTAINER_UID="${CURRENT_UID}" \
    CONTAINER_GID="${CURRENT_GID}" \
    CONTAINER_HOME="${TEST_ROOT}/home/conflict" \
    CONTAINER_SHELL=/bin/sh \
    Sources/Plugins/MachineAPIServer/Resources/create-user.sh; then
    echo "create-user accepted an existing username with a different UID" >&2
    exit 1
fi
