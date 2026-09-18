# Match the Containerization EXT4 decoding fix across consumers

<!-- markdownlint-disable MD013 -->

## Problem and reproduction

The native Compose Thread Sanitizer suite exposed a real unaligned-load trap in Containerization's EXT4 reader. The generic source fix is [Containerization PR 103](https://github.com/stephenlclarke/containerization/pull/103), source commit `ea5ff3b97bd1a12c4054f262ce9fbb7207e6f443`. Moving only Compose's direct dependency leaves Container requiring `51bf8a10e2036861f87ccdf2fd881a8726c534d2`; SwiftPM correctly refuses the two conflicting revision requirements. GitHub Compose ASan job `105455539091` in run `35298336853` records that exact conflict before testing.

## Expected behavior and scope

Container's manifest and lock should select the same reviewed generic fix as its consumer. This is a two-field pin change; there are no Container runtime source changes, installed-service changes, guest image substitutions or stock Apple changes. It does not certify a release or permit a missing guest image to be replaced with an unrelated artifact.

## Ownership and completion

The active Container-family Bazel migration owns this isolated `fix/ext4-dependency-alignment` branch. Merge the lower dependency PR and this PR only after exact-head review and required checks, then admit the matched Compose pin. Preserve the old failure evidence. No Apple remote writes are authorized.
