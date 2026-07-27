#! /bin/bash -e
# Copyright © 2025-2026 Apple Inc. and the container project authors.
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

usage() {
    cat <<EOF
Usage: $(basename "$0") [-a APP_ROOT | --app-root APP_ROOT] [-l LOG_ROOT | --log-root LOG_ROOT] [--enable-kernel-install | --disable-kernel-install] [-h | --help]

Install the init image for container system.

Options:
    -a, --app-root APP_ROOT    Install the init image under the APP_ROOT path
    -l, --log-root LOG_ROOT    Install the init image under the LOG_ROOT path
    --enable-kernel-install    Install the recommended default kernel if it is missing
    --disable-kernel-install   Do not install the default kernel if it is missing
    -h, --help                 Show this help message

Environment:
    CONTAINER_INIT_IMAGE_NAME
                               Image reference to build and install for the
                               init image (default: vminit:latest)
    CONTAINERIZATION_INIT_SOURCE_PATH
                               Build the init image from this containerization
                               checkout instead of the SwiftPM resolved path

EOF
    exit 0
}

# Parse command line options
START_ARGS=()
BUILD_START_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--app-root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Option $1 requires an argument." >&2
                usage
            fi
            START_ARGS+=(--app-root "$2")
            shift 2
            ;;
        -l|--log-root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Option $1 requires an argument." >&2
                usage
            fi
            START_ARGS+=(--log-root "$2")
            shift 2
            ;;
        --enable-kernel-install|--disable-kernel-install)
            START_ARGS+=("$1")
            BUILD_START_ARGS+=("$1")
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Invalid option: $1" >&2
            usage
            ;;
    esac
done

CONTAINER_INIT_CLI="${CONTAINER_INIT_CLI:-bin/container}"
CONTAINER_INIT_MAKE="${CONTAINER_INIT_MAKE:-make}"
CONTAINER_INIT_SWIFT="${CONTAINER_INIT_SWIFT:-/usr/bin/swift}"
IMAGE_NAME="${CONTAINER_INIT_IMAGE_NAME:-vminit:latest}"
INIT_IMAGE_TAR=""
TEMP_CONTAINERIZATION_ROOT=""
BOOTSTRAP_RUNTIME_STARTED=false

cleanup() {
	if [[ "${BOOTSTRAP_RUNTIME_STARTED}" == "true" ]]; then
		"${CONTAINER_INIT_CLI}" system stop >/dev/null 2>&1 || true
	fi
	if [[ -n "${INIT_IMAGE_TAR}" && -f "${INIT_IMAGE_TAR}" ]]; then
		rm -f "${INIT_IMAGE_TAR}"
	fi
	if [[ -n "${TEMP_CONTAINERIZATION_ROOT}" && -d "${TEMP_CONTAINERIZATION_ROOT}" ]]; then
		rm -rf "${TEMP_CONTAINERIZATION_ROOT}"
	fi
}

trap cleanup EXIT

copy_containerization_checkout() {
	local source_path="$1"
	TEMP_CONTAINERIZATION_ROOT="$(mktemp -d)"
	CONTAINERIZATION_PATH="${TEMP_CONTAINERIZATION_ROOT}/containerization"
	mkdir -p "${CONTAINERIZATION_PATH}"
	cp -R "${source_path}/." "${CONTAINERIZATION_PATH}/"
	chmod -R u+w "${CONTAINERIZATION_PATH}"
}

CONTAINERIZATION_VERSION="$(${CONTAINER_INIT_SWIFT} package show-dependencies --format json | jq -r '.dependencies[] | select(.identity == "containerization") | .version')"
CONTAINERIZATION_PATH="${CONTAINERIZATION_INIT_SOURCE_PATH:-}"
if [[ -n "${CONTAINERIZATION_PATH}" || "${CONTAINERIZATION_VERSION}" == "unspecified" ]] ; then
	if [[ -z "${CONTAINERIZATION_PATH}" ]]; then
		CONTAINERIZATION_PATH="$(${CONTAINER_INIT_SWIFT} package show-dependencies --format json | jq -r '.dependencies[] | select(.identity == "containerization") | .path')"
	fi
	if [ ! -d "${CONTAINERIZATION_PATH}" ] ; then
		echo "containerization directory at ${CONTAINERIZATION_PATH} does not exist"
		exit 1
	fi
	if [ ! -w "${CONTAINERIZATION_PATH}/Package.swift" ] ; then
		echo "containerization is a read-only source-control checkout; copying to a writable init image build directory"
		copy_containerization_checkout "${CONTAINERIZATION_PATH}"
	fi
	echo "Creating InitImage from ${CONTAINERIZATION_PATH}"
	if ! "${CONTAINER_INIT_CLI}" system status >/dev/null 2>&1; then
		BOOTSTRAP_RUNTIME_STARTED=true
	fi
	"${CONTAINER_INIT_CLI}" --debug system start --timeout 60 "${BUILD_START_ARGS[@]}"
	"${CONTAINER_INIT_MAKE}" -C "${CONTAINERIZATION_PATH}" init VMINIT_IMAGE="${IMAGE_NAME}"
	INIT_IMAGE_TAR="$(mktemp -t container-init.XXXXXX.tar)"
	"${CONTAINERIZATION_PATH}/bin/cctl" images save -o "${INIT_IMAGE_TAR}" "${IMAGE_NAME}"

	# Sleep because commands after stop and start are racy.
	"${CONTAINER_INIT_CLI}" system stop
	BOOTSTRAP_RUNTIME_STARTED=false
	sleep 3
	"${CONTAINER_INIT_CLI}" --debug system start "${START_ARGS[@]}"
	sleep 3
	"${CONTAINER_INIT_CLI}" i load -i "${INIT_IMAGE_TAR}"
fi
