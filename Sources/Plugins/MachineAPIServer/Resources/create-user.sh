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

#
# First-time container user setup. Intended to be container machine-agnostic
# by directly manipulating /etc/group, /etc/passwd, and /etc/shadow rather
# than relying on image-specific tools (useradd, adduser, etc.). Also
# populates the home directory from /etc/skel and grants passwordless sudo
# access.
#
# Expects CONTAINER_USER, CONTAINER_UID, CONTAINER_GID, and CONTAINER_HOME to
# be set in the environment.
#

set -e

etc_root=${CONTAINER_ETC_ROOT:-/etc}
passwd_file=${etc_root}/passwd
group_file=${etc_root}/group
shadow_file=${etc_root}/shadow

if ! awk -F: -v gid="${CONTAINER_GID}" '$3 == gid { found = 1 } END { exit !found }' "${group_file}"; then
    echo "${CONTAINER_USER}:x:${CONTAINER_GID}:" >> "${group_file}"
fi

existing_uid=$(awk -F: -v user="${CONTAINER_USER}" '$1 == user { print $3; exit }' "${passwd_file}")
if [ -n "${existing_uid}" ] && [ "${existing_uid}" != "${CONTAINER_UID}" ]; then
    echo "container machine user '${CONTAINER_USER}' already exists with UID ${existing_uid}, expected ${CONTAINER_UID}" >&2
    exit 1
fi

existing_gid=$(awk -F: -v user="${CONTAINER_USER}" '$1 == user { print $4; exit }' "${passwd_file}")
if [ -n "${existing_gid}" ] && [ "${existing_gid}" != "${CONTAINER_GID}" ]; then
    echo "container machine user '${CONTAINER_USER}' already exists with GID ${existing_gid}, expected ${CONTAINER_GID}" >&2
    exit 1
fi

if [ -z "${existing_uid}" ]; then
    # The requested UID may already belong to another image account. A second
    # name for that numeric identity is valid and ensures the persisted machine
    # username remains resolvable for subsequent boots and commands.
    echo "${CONTAINER_USER}:x:${CONTAINER_UID}:${CONTAINER_GID}::${CONTAINER_HOME}:${CONTAINER_SHELL}" >> "${passwd_file}"
    echo "${CONTAINER_USER}:!:19000:0:99999:7:::" >> "${shadow_file}"
fi

mkdir -p "${CONTAINER_HOME}"
if [ -d "${etc_root}/skel" ]; then
    cp -a "${etc_root}/skel/." "${CONTAINER_HOME}"
fi
chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${CONTAINER_HOME}"

mkdir -p "${etc_root}/sudoers.d"
sudoers_file=$(echo "${CONTAINER_USER}" | tr '.' '_')
echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" > "${etc_root}/sudoers.d/${sudoers_file}"
chmod 440 "${etc_root}/sudoers.d/${sudoers_file}"
