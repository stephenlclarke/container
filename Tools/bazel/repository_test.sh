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

# USAGE: repository_test.sh TEST_PATH
# Run an existing repository test within the declared Bazel source view.
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: %s TEST_PATH\n' "$(basename "$0")"
    exit 0
fi

[[ $# == 1 && -f "$1" ]] || { printf 'Expected one declared test path.\n' >&2; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
case "$1" in
    *.sh)
        if [[ "${CONTAINER_TEST_TRACE:-0}" == 1 ]]; then
            exec /bin/bash -x "$1"
        fi
        exec /bin/bash "$1"
        ;;
    *.py) exec /usr/bin/python3 "$1" ;;
    *) printf 'Unsupported test path: %s\n' "$1" >&2; exit 2 ;;
esac
