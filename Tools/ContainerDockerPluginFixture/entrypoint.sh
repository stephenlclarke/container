#!/bin/sh
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu
umask 077

plugin_socket=
expect_socket=false
for argument in "$@"; do
    if test "${expect_socket}" = true; then
        plugin_socket="${argument}"
        expect_socket=false
    elif test "${argument}" = "--plugin-socket"; then
        expect_socket=true
    fi
done

case "${plugin_socket}" in
    /run/docker/plugins/*) ;;
    *)
        echo "container-docker-plugin-entrypoint: invalid private plugin socket" >&2
        exit 1
        ;;
esac

state_root=/var/lib/container-docker-plugin-service
history_path="${state_root}/fixture-history.bin"
mkdir -p "${state_root}" "$(dirname "${plugin_socket}")"

ensure_private_directory() {
    directory=$1
    if chmod 0700 "${directory}" 2>/dev/null; then
        return 0
    fi
    test ! -L "${directory}" \
        && test -d "${directory}" \
        && test "$(stat -c '%a' "${directory}")" = 700
}

# A macOS virtiofs directory can preserve its host-enforced mode while
# rejecting a redundant guest chmod with EPERM. Accept that transport behavior
# only when an immediate inspection confirms the exact protected mode.
ensure_private_directory "${state_root}"
ensure_private_directory "$(dirname "${plugin_socket}")"
rm -f "${plugin_socket}"

/usr/local/libexec/container-docker-plugin-fixture \
    --socket "${plugin_socket}" \
    --history "${history_path}" &
plugin_pid=$!
service_pid=

terminate() {
    if test -n "${service_pid}"; then
        kill -TERM "${service_pid}" 2>/dev/null || true
    fi
    kill -TERM "${plugin_pid}" 2>/dev/null || true
}
trap terminate INT TERM HUP

ready=false
attempt=0
while test "${attempt}" -lt 100; do
    if test -S "${plugin_socket}"; then
        ready=true
        break
    fi
    if ! kill -0 "${plugin_pid}" 2>/dev/null; then
        wait "${plugin_pid}" || true
        echo "container-docker-plugin-entrypoint: fixture exited before readiness" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.05
done
if test "${ready}" != true; then
    terminate
    wait "${plugin_pid}" || true
    echo "container-docker-plugin-entrypoint: fixture readiness timed out" >&2
    exit 1
fi

/usr/local/libexec/container-docker-plugin-service "$@" &
service_pid=$!
while kill -0 "${service_pid}" 2>/dev/null \
    && kill -0 "${plugin_pid}" 2>/dev/null; do
    sleep 1
done

set +e
wait "${service_pid}"
service_status=$?
set -e
kill -TERM "${plugin_pid}" 2>/dev/null || true
wait "${plugin_pid}" || true
exit "${service_status}"
