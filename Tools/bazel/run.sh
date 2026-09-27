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

# USAGE: run.sh <build|test|coverage|query|cquery|aquery|info|shutdown> [Bazel arguments]
# Uses the enrolled external SSD and pinned Bazel. Saves logs on internal storage.
set -euo pipefail
readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
error() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
usage() { printf 'Usage: %s <build|test|coverage|query|cquery|aquery|info|shutdown> [Bazel arguments]\n' "$SCRIPT_NAME"; }
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    build|test|coverage|query|cquery|aquery|info|shutdown) command_name="$1"; shift ;;
    *) usage >&2; exit 2 ;;
esac
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
repo="$(cd "$(dirname "$SELF_PATH")/../.." && pwd -P)"
readonly volume=/Volumes/SSD
readonly storage="$volume/cf/container-only"
readonly retained="$HOME/Library/Application Support/ContainerFamily/retained/container-only"
readonly enrollment="$HOME/Library/Application Support/ContainerFamily/retained/workflow/ssd-volume.uuid"
[[ -f "$enrollment" ]] || { error 'Missing SSD enrollment.'; exit 2; }
read -r expected_uuid < "$enrollment"
metadata="$(/usr/sbin/diskutil info -plist "$volume")"
actual_uuid="$(printf '%s' "$metadata" | /usr/bin/plutil -extract VolumeUUID raw -)"
mount="$(printf '%s' "$metadata" | /usr/bin/plutil -extract MountPoint raw -)"
internal="$(printf '%s' "$metadata" | /usr/bin/plutil -extract Internal raw -)"
[[ "$actual_uuid" == "$expected_uuid" && "$mount" == "$volume" && "$internal" == false ]] || { error 'The enrolled external SSD is unavailable.'; exit 2; }
readonly bazel="$volume/cf/bazel/bootstrap/bazel-8.8.0-darwin-arm64"
readonly expected_sha=f0ac192aba2ccaa373cdfd527d4c407cc492c1296a2f11a4b67563e4d5aa9acb
read -r version < "$repo/.bazelversion"
[[ "$version" == 8.8.0 ]] || { error 'Unsupported Bazel version.'; exit 2; }
actual_sha="$(/usr/bin/shasum -a 256 "$bazel")"
[[ "${actual_sha%% *}" == "$expected_sha" ]] || { error 'Bazel checksum mismatch.'; exit 2; }
umask 077
for directory in "$storage" "$storage/tmp" "$storage/output" "$storage/cache" "$storage/repositories" "$retained"; do
    [[ ! -L "$directory" ]] || { error "Refusing symlinked storage: $directory"; exit 2; }
done
mkdir -p "$storage/tmp" "$storage/output" "$storage/cache" "$storage/repositories" "$retained"
export TMPDIR="$storage/tmp/" TMP="$storage/tmp/" TEMP="$storage/tmp/"
cd "$repo"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
{
    printf 'source=%s\nhead=%s\n' "$repo" "$(git rev-parse HEAD)"
    git status --short
    /usr/bin/sw_vers
    /usr/bin/xcodebuild -version
    /usr/bin/xcrun swift --version 2>&1
} > "$retained/$run_id.source.txt"
printf 'Evidence: %s/%s.log\n' "$retained" "$run_id"
git diff --binary HEAD > "$retained/$run_id.diff"
find Tools/bazel Tools/ContainerSemanticHelper -type f -exec /usr/bin/shasum -a 256 {} \; > "$retained/$run_id.inputs.sha256"
/usr/bin/shasum -a 256 MODULE.bazel MODULE.bazel.lock BUILD.bazel .bazelrc .bazelversion Package.swift Package.resolved Makefile >> "$retained/$run_id.inputs.sha256"
extra=()
case "$command_name" in
    build|test|coverage) extra+=("--build_event_json_file=$retained/$run_id.events.json") ;;
    shutdown) exec "$bazel" --output_user_root="$storage/output" shutdown ;;
esac
set +e
"$bazel" --output_user_root="$storage/output" "$command_name" \
    --repository_cache="$storage/repositories" "${extra[@]}" "$@" 2>&1 | tee "$retained/$run_id.log"
status=${PIPESTATUS[0]}
set -e
if [[ -f "$retained/$run_id.events.json" ]]; then
    /usr/bin/python3 Tools/bazel/retain_tests.py "$retained/$run_id.events.json"
fi
exit "$status"
