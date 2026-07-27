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
if [[ "$*" == "system status" ]]; then
    test -f "${INSTALL_INIT_TEST_RUNNING}"
    exit
fi
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
if [[ "${INSTALL_INIT_TEST_FAILURE:-}" == "make" ]]; then
    exit 42
fi
EOF

cat > "${CONTAINERIZATION_PATH}/bin/cctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'cctl %s\n' "$*" >> "${INSTALL_INIT_TEST_LOG}"
if [[ "${INSTALL_INIT_TEST_FAILURE:-}" == "save" ]]; then
    exit 43
fi
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

run_failure_case() {
    local stage="$1"
    local failure_log_path="${TEST_ROOT}/${stage}-failure.log"
    local failure_running_path="${TEST_ROOT}/${stage}-failure-running"

    if INSTALL_INIT_TEST_LOG="${failure_log_path}" \
        INSTALL_INIT_TEST_RUNNING="${failure_running_path}" \
        INSTALL_INIT_TEST_FAILURE="${stage}" \
        CONTAINER_INIT_CLI="${FAKE_CONTAINER}" \
        CONTAINER_INIT_MAKE="${FAKE_MAKE}" \
        CONTAINER_INIT_SWIFT="${FAKE_SWIFT}" \
        CONTAINERIZATION_INIT_SOURCE_PATH="${CONTAINERIZATION_PATH}" \
        CONTAINER_INIT_IMAGE_NAME="test-init:latest" \
        scripts/install-init.sh --enable-kernel-install --app-root "${TEST_ROOT}/app"
    then
        printf 'expected %s failure\n' "${stage}" >&2
        exit 1
    fi

    test ! -e "${failure_running_path}"
    grep -q '^container --debug system start --timeout 60' "${failure_log_path}"
    grep -q '^container system stop$' "${failure_log_path}"
}

run_failure_case make
run_failure_case save

PREEXISTING_LOG_PATH="${TEST_ROOT}/preexisting.log"
PREEXISTING_RUNNING_PATH="${TEST_ROOT}/preexisting-running"
touch "${PREEXISTING_RUNNING_PATH}"

INSTALL_INIT_TEST_LOG="${PREEXISTING_LOG_PATH}" \
INSTALL_INIT_TEST_RUNNING="${PREEXISTING_RUNNING_PATH}" \
CONTAINER_INIT_CLI="${FAKE_CONTAINER}" \
CONTAINER_INIT_MAKE="${FAKE_MAKE}" \
CONTAINER_INIT_SWIFT="${FAKE_SWIFT}" \
CONTAINERIZATION_INIT_SOURCE_PATH="${CONTAINERIZATION_PATH}" \
CONTAINER_INIT_IMAGE_NAME="test-init:latest" \
    scripts/install-init.sh --enable-kernel-install --app-root "${TEST_ROOT}/app"

if grep -q '^container --debug system start --timeout 60' "${PREEXISTING_LOG_PATH}"; then
    printf 'pre-existing runtime was started again\n' >&2
    exit 1
fi
grep -q '^container system stop$' "${PREEXISTING_LOG_PATH}"
grep -q '^container --debug system start --enable-kernel-install' "${PREEXISTING_LOG_PATH}"

INTEGRATION_SCRATCH_ROOT="${TEST_ROOT}/integration-scratch"
INTEGRATION_DRY_RUN="$(
    make -n \
        MAKE=true \
        SCRATCH_ROOT="${INTEGRATION_SCRATCH_ROOT}" \
        integration
)"

if grep -q '^scripts/install-init.sh ' <<<"${INTEGRATION_DRY_RUN}"; then
    printf 'integration invoked init-block before the isolated execution sequence\n' >&2
    exit 1
fi
grep -Fq \
    "XDG_CONFIG_HOME=\"${INTEGRATION_SCRATCH_ROOT}/xdg-config\" \"true\" init-block" \
    <<<"${INTEGRATION_DRY_RUN}"
