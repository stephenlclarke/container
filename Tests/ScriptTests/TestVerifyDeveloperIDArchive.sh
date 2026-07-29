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

PAYLOAD="${TEST_ROOT}/payload"
mkdir -p "${PAYLOAD}/bin"
printf 'first\n' > "${PAYLOAD}/bin/first"
printf 'second\n' > "${PAYLOAD}/bin/second"
printf 'resource\n' > "${PAYLOAD}/resource.txt"
chmod +x "${PAYLOAD}/bin/first" "${PAYLOAD}/bin/second"
tar -czf "${TEST_ROOT}/package.tar.gz" -C "${PAYLOAD}" .

FAKE_FILE="${TEST_ROOT}/file"
cat > "${FAKE_FILE}" <<'EOF'
#!/bin/bash
if [[ "$2" == *.txt ]]; then
    printf 'ASCII text\n'
else
    printf 'Mach-O 64-bit executable arm64\n'
fi
EOF
chmod +x "${FAKE_FILE}"

write_codesign() {
    local authority="$1"
    local flags="$2"
    local mixed_team="$3"
    cat > "${TEST_ROOT}/codesign" <<EOF
#!/bin/bash
if [[ "\$1" == "--verify" ]]; then
    exit 0
fi
path="\${@: -1}"
team=ABCDEFGHIJ
if [[ "${mixed_team}" == "true" && "\${path}" == *second ]]; then
    team=ZZZZZZZZZZ
fi
cat >&2 <<'SIGNATURE'
${flags}
${authority}
Timestamp=29 Jul 2026 at 12:00:00
SIGNATURE
printf 'TeamIdentifier=%s\n' "\${team}" >&2
EOF
    chmod +x "${TEST_ROOT}/codesign"
}

run_verifier() {
    CODESIGN="${TEST_ROOT}/codesign" \
    FILE_COMMAND="${FAKE_FILE}" \
        scripts/verify-developer-id-archive.sh "${TEST_ROOT}/package.tar.gz"
}

DEVELOPER_ID_AUTHORITIES=$'Authority=Developer ID Application: Stephen Clarke (ABCDEFGHIJ)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA'

write_codesign \
    "${DEVELOPER_ID_AUTHORITIES}" \
    'CodeDirectory v=20500 size=128 flags=0x10000(runtime) hashes=2+2 location=embedded' \
    false
output="$(run_verifier)"
grep -q 'Verified 2 Developer ID signed Mach-O binaries' <<<"${output}"

write_codesign \
    'Signature=adhoc' \
    'CodeDirectory v=20500 size=128 flags=0x10000(runtime) hashes=2+2 location=embedded' \
    false
if run_verifier >"${TEST_ROOT}/adhoc.out" 2>"${TEST_ROOT}/adhoc.err"; then
    printf 'ad hoc signature unexpectedly passed verification\n' >&2
    exit 1
fi
grep -q 'not signed by a Developer ID Application' "${TEST_ROOT}/adhoc.err"

write_codesign \
    "${DEVELOPER_ID_AUTHORITIES}" \
    'CodeDirectory v=20500 size=128 flags=0x0(none) hashes=2+2 location=embedded' \
    false
if run_verifier >"${TEST_ROOT}/runtime.out" 2>"${TEST_ROOT}/runtime.err"; then
    printf 'signature without hardened runtime unexpectedly passed verification\n' >&2
    exit 1
fi
grep -q 'missing the hardened runtime' "${TEST_ROOT}/runtime.err"

write_codesign \
    "${DEVELOPER_ID_AUTHORITIES}" \
    'CodeDirectory v=20500 size=128 flags=0x10000(runtime) hashes=2+2 location=embedded' \
    true
if run_verifier >"${TEST_ROOT}/teams.out" 2>"${TEST_ROOT}/teams.err"; then
    printf 'mixed Developer ID teams unexpectedly passed verification\n' >&2
    exit 1
fi
grep -q 'archive mixes Developer ID teams' "${TEST_ROOT}/teams.err"

write_codesign \
    'Authority=Developer ID Application: Stephen Clarke (ABCDEFGHIJ)' \
    'CodeDirectory v=20500 size=128 flags=0x10000(runtime) hashes=2+2 location=embedded' \
    false
if run_verifier >"${TEST_ROOT}/chain.out" 2>"${TEST_ROOT}/chain.err"; then
    printf 'signature without the Apple certificate chain unexpectedly passed verification\n' >&2
    exit 1
fi
grep -q 'does not chain through the Developer ID certification authority' \
    "${TEST_ROOT}/chain.err"

printf 'escape\n' > "${TEST_ROOT}/escape"
python3 - "${TEST_ROOT}" <<'PY'
from pathlib import Path
import sys
import tarfile

root = Path(sys.argv[1])
with tarfile.open(root / "unsafe.tar.gz", "w:gz") as archive:
    archive.add(root / "escape", arcname="../escape")
PY
if CODESIGN="${TEST_ROOT}/codesign" \
    FILE_COMMAND="${FAKE_FILE}" \
    scripts/verify-developer-id-archive.sh "${TEST_ROOT}/unsafe.tar.gz" \
    >"${TEST_ROOT}/unsafe.out" 2>"${TEST_ROOT}/unsafe.err"
then
    printf 'archive path escape unexpectedly passed verification\n' >&2
    exit 1
fi
grep -q 'unsafe archive path' "${TEST_ROOT}/unsafe.err"

WORKFLOW=".github/workflows/prebuilt-binaries.yml"
grep -Fq 'secrets.DEVELOPER_ID_APPLICATION_P12_BASE64' "${WORKFLOW}"
grep -Fq 'secrets.DEVELOPER_ID_APPLICATION_P12_PASSWORD' "${WORKFLOW}"
grep -Fq 'scripts/verify-developer-id-archive.sh' "${WORKFLOW}"
grep -Fq 'security list-keychains' "${WORKFLOW}"
grep -Fq 'developer-id-signing-probe-' "${WORKFLOW}"
grep -Fq 'DEVELOPER_ID_ORIGINAL_KEYCHAINS' "${WORKFLOW}"
grep -Fq 'restore_keychain_search_list' "${WORKFLOW}"
# The workflow assertions intentionally match literal shell variable references.
# shellcheck disable=SC2016
grep -Fq -- '--keychain "${DEVELOPER_ID_KEYCHAIN}"' "${WORKFLOW}"
# shellcheck disable=SC2016
grep -Fq 'CODESIGN_OPTS="--force --keychain ${DEVELOPER_ID_KEYCHAIN} --sign ${DEVELOPER_ID_APPLICATION_IDENTITY}' "${WORKFLOW}"
grep -Fq 'security delete-keychain' "${WORKFLOW}"
[[ "$(grep -Fc -- '--options runtime' "${WORKFLOW}")" -eq 2 ]]
[[ "$(grep -Fc -- '--timestamp' "${WORKFLOW}")" -eq 2 ]]
