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

# USAGE:
#   ensure-journald-builder.sh
#
# Install missing local build tools, start Colima when required, and bootstrap
# the Buildx builder used by the pinned journald-service workload.
#
# Environment:
#   CONTAINER_JOURNALD_BUILDER             Buildx builder name (default: colima)
#   CONTAINER_JOURNALD_BUILDER_CPUS        Colima CPUs when starting (default: 4)
#   CONTAINER_JOURNALD_BUILDER_MEMORY_GIB  Colima GiB when starting (default: 8)

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "${SELF_PATH}")"
readonly SCRIPT_NAME
readonly BUILDER="${CONTAINER_JOURNALD_BUILDER:-colima}"
readonly BUILDER_CPUS="${CONTAINER_JOURNALD_BUILDER_CPUS:-4}"
readonly BUILDER_MEMORY_GIB="${CONTAINER_JOURNALD_BUILDER_MEMORY_GIB:-8}"

# Print command usage.
usage() {
    printf 'Usage: %s\n' "${SCRIPT_NAME}"
}

# Print an informational message.
info() {
    printf '%s\n' "$*"
}

# Print an error message.
error() {
    printf '%s\n' "$*" >&2
}

# Install any missing Docker, Colima, or Buildx packages with Homebrew.
install_missing_tools() {
    local -a missing=()

    if ! command -v docker >/dev/null 2>&1; then
        missing+=(docker)
    fi
    if ! command -v colima >/dev/null 2>&1; then
        missing+=(colima)
    fi
    if ! docker buildx version >/dev/null 2>&1; then
        missing+=(docker-buildx)
    fi
    if ((${#missing[@]} == 0)); then
        return
    fi
    if ! command -v brew >/dev/null 2>&1; then
        error "Homebrew is required to install: ${missing[*]}"
        exit 1
    fi

    info "Installing missing journald builder tools: ${missing[*]}"
    brew install "${missing[@]}"
}

# Expose Homebrew's Buildx binary as a Docker CLI plugin when necessary.
ensure_buildx_plugin() {
    local buildx_binary
    local plugin_directory

    if docker buildx version >/dev/null 2>&1; then
        return
    fi
    buildx_binary="$(brew --prefix docker-buildx)/bin/docker-buildx"
    plugin_directory="${HOME}/.docker/cli-plugins"
    mkdir -p "${plugin_directory}"
    ln -sf "${buildx_binary}" "${plugin_directory}/docker-buildx"
    docker buildx version >/dev/null
}

# Start the local Colima daemon when it is not already available.
ensure_colima() {
    if colima status >/dev/null 2>&1; then
        return
    fi

    info "Starting Colima for the journald workload builder"
    colima start \
        --cpu "${BUILDER_CPUS}" \
        --memory "${BUILDER_MEMORY_GIB}"
}

# Create and bootstrap the configured Linux/arm64-capable Buildx builder.
ensure_builder() {
    if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
        info "Creating Buildx builder: ${BUILDER}"
        docker buildx create \
            --name "${BUILDER}" \
            --driver docker-container \
            colima >/dev/null
    fi
    docker buildx inspect "${BUILDER}" --bootstrap >/dev/null
}

# Validate configuration and prepare the local builder.
main() {
    if (($# != 0)); then
        if (($# == 1)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
            usage
            return
        fi
        usage >&2
        exit 2
    fi
    if [[ ! "${BUILDER}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then
        error "Invalid CONTAINER_JOURNALD_BUILDER: ${BUILDER}"
        exit 1
    fi

    install_missing_tools
    ensure_buildx_plugin
    ensure_colima
    ensure_builder
}

main "$@"
