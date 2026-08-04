#!/bin/sh
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

set -eu
umask 077

state_root=/var/lib/container-journald-service
machine_id_path="${state_root}/machine-id"
mkdir -p "${state_root}" /run/systemd/journal /var/log/journal

ensure_private_directory() {
    directory=$1
    if chmod 0700 "${directory}" 2>/dev/null; then
        return 0
    fi
    test ! -L "${directory}" \
        && test -d "${directory}" \
        && test "$(stat -c '%a' "${directory}")" = 700
}

ensure_private_file() {
    file=$1
    if chmod 0600 "${file}" 2>/dev/null; then
        return 0
    fi
    test ! -L "${file}" \
        && test -f "${file}" \
        && test "$(stat -c '%a' "${file}")" = 600
}

# macOS virtiofs can preserve host-enforced modes while rejecting redundant
# guest chmod calls with EPERM. Accept that behavior only after exact-mode and
# file-type inspection.
ensure_private_directory "${state_root}"

if test -L "${machine_id_path}"; then
    echo "container-journald-entrypoint: refusing symbolic-link machine ID" >&2
    exit 1
fi
if ! test -f "${machine_id_path}" \
    || ! grep -Eq '^[0-9a-f]{32}$' "${machine_id_path}"; then
    temporary_id="${machine_id_path}.tmp.$$"
    tr -d '-' </proc/sys/kernel/random/uuid >"${temporary_id}"
    ensure_private_file "${temporary_id}"
    mv "${temporary_id}" "${machine_id_path}"
fi
ensure_private_file "${machine_id_path}"
if test "$(readlink /etc/machine-id)" != "${machine_id_path}"; then
    echo "container-journald-entrypoint: invalid immutable machine ID link" >&2
    exit 1
fi

/lib/systemd/systemd-journald &
journal_pid=$!
service_pid=

terminate() {
    if test -n "${service_pid}"; then
        kill -TERM "${service_pid}" 2>/dev/null || true
    fi
    kill -TERM "${journal_pid}" 2>/dev/null || true
}
trap terminate INT TERM HUP

ready=false
attempt=0
while test "${attempt}" -lt 100; do
    if test -S /run/systemd/journal/socket; then
        ready=true
        break
    fi
    if ! kill -0 "${journal_pid}" 2>/dev/null; then
        wait "${journal_pid}" || true
        echo "container-journald-entrypoint: systemd-journald exited before readiness" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.05
done
if test "${ready}" != true; then
    terminate
    wait "${journal_pid}" || true
    echo "container-journald-entrypoint: systemd-journald readiness timed out" >&2
    exit 1
fi

/usr/local/libexec/container-journald-service "$@" &
service_pid=$!
while kill -0 "${service_pid}" 2>/dev/null \
    && kill -0 "${journal_pid}" 2>/dev/null; do
    sleep 1
done

if kill -0 "${service_pid}" 2>/dev/null; then
    echo "container-journald-entrypoint: systemd-journald exited unexpectedly" >&2
    kill -TERM "${service_pid}" 2>/dev/null || true
    wait "${service_pid}" || true
    wait "${journal_pid}" || true
    exit 1
fi

set +e
wait "${service_pid}"
service_status=$?
set -e
kill -TERM "${journal_pid}" 2>/dev/null || true
wait "${journal_pid}" || true
exit "${service_status}"
