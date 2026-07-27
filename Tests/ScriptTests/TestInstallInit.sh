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

LOG_PATH="${TEST_ROOT}/operations.log"
RUNNING_PATH="${TEST_ROOT}/running"
CONTAINERIZATION_PATH="${TEST_ROOT}/containerization"
mkdir -p "${CONTAINERIZATION_PATH}/bin"
touch "${CONTAINERIZATION_PATH}/Package.swift"

FAKE_SWIFT="${TEST_ROOT}/swift"
FAKE_CONTAINER="${TEST_ROOT}/container"
FAKE_MAKE="${TEST_ROOT}/make"

cat > "${FAKE_SWIFT}" <<EOF
#!/bin/bash
printf '%s\n' '{"dependencies":[{"identity":"containerization","version":"unspecified","path":"${CONTAINERIZATION_PATH}"}]}'
EOF

cat > "${FAKE_CONTAINER}" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'container %s\n' "$*" >> "${INSTALL_INIT_TEST_LOG}"
if [[ "$*" == *"system start"* ]]; then
    touch "${INSTALL_INIT_TEST_RUNNING}"
elif [[ "$*" == *"system stop"* ]]; then
    rm -f "${INSTALL_INIT_TEST_RUNNING}"
elif [[ "$*" == *"i load"* ]]; then
    test -f "${INSTALL_INIT_TEST_RUNNING}"
fi
EOF

cat > "${FAKE_MAKE}" <<'EOF'
#!/bin/bash
set -euo pipefail
test -f "${INSTALL_INIT_TEST_RUNNING}"
printf 'make %s\n' "$*" >> "${INSTALL_INIT_TEST_LOG}"
EOF

cat > "${CONTAINERIZATION_PATH}/bin/cctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'cctl %s\n' "$*" >> "${INSTALL_INIT_TEST_LOG}"
while (($# > 0)); do
    if [[ "$1" == "-o" ]]; then
        touch "$2"
        break
    fi
    shift
done
EOF

chmod +x \
    "${FAKE_SWIFT}" \
    "${FAKE_CONTAINER}" \
    "${FAKE_MAKE}" \
    "${CONTAINERIZATION_PATH}/bin/cctl"

INSTALL_INIT_TEST_LOG="${LOG_PATH}" \
INSTALL_INIT_TEST_RUNNING="${RUNNING_PATH}" \
CONTAINER_INIT_CLI="${FAKE_CONTAINER}" \
CONTAINER_INIT_MAKE="${FAKE_MAKE}" \
CONTAINER_INIT_SWIFT="${FAKE_SWIFT}" \
CONTAINERIZATION_INIT_SOURCE_PATH="${CONTAINERIZATION_PATH}" \
CONTAINER_INIT_IMAGE_NAME="test-init:latest" \
    scripts/install-init.sh --enable-kernel-install --app-root "${TEST_ROOT}/app"

OPERATIONS=()
while IFS= read -r operation; do
    OPERATIONS+=("${operation}")
done < "${LOG_PATH}"
EXPECTED=(
    "container --debug system start --timeout 60 --enable-kernel-install"
    "make -C ${CONTAINERIZATION_PATH} init VMINIT_IMAGE=test-init:latest"
    "cctl images save -o"
    "container system stop"
    "container --debug system start --enable-kernel-install --app-root ${TEST_ROOT}/app"
    "container i load -i"
)

[[ "${#OPERATIONS[@]}" -eq "${#EXPECTED[@]}" ]]
for index in "${!EXPECTED[@]}"; do
    [[ "${OPERATIONS[${index}]}" == "${EXPECTED[${index}]}"* ]]
done
