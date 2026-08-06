<!-- markdownlint-disable MD013 -->

# Runtime gap: local logging compression start diagnostic

## Problem

Docker Engine defers local-driver rotation validation until container start. When local compression is effective and `max-file=1`, Docker retains the created container and returns `compression cannot be enabled when max file count is 1`. Container used the json-file fallback diagnostic, `compress cannot be true when max-file is less than 2 or max-size is not set`, even though local has a concrete default maximum size and the failure is specifically the one-file policy.

This affects Docker-compatible REST clients and the native authority alike. It is an upstream Container behavior gap, not a Compose parsing concern.

## Required behavior

- Preserve Docker's start-time (not create-time) validation boundary for `local` compression.
- Preserve the created container and its configured local options after the failed start.
- Emit Docker's local one-file diagnostic: `compression cannot be enabled when max file count is 1`.
- Keep json-file's generic missing-size/one-file diagnostic unchanged.
- Retain a focused public-socket certificate for rotation, restart retention, tailing, and the invalid local start.

## Acceptance evidence

- [x] Pinned Docker Engine 29.2.1 oracle records the local one-file message, retained `created` state, and configured options.
- [x] Container's start validator selects the local-specific diagnostic only when local compression has an effective one-file policy.
- [x] The generic json-file diagnostic remains covered by the existing start-validator cases.
- [x] The public Docker CLI certificate covers compressed 4 KiB/3-file local rotation, retained history across restart, tailing, and the one-file failure.
- [ ] Build the exact current local Container artifact and pass the public-socket certificate through it.
- [ ] Run the focused Swift regression through a target-only build path; `swift test --filter` currently expands into the whole package graph and was stopped before test execution.

## Apple-shaped boundary

The change is retained only on the local `upstream/logging-driver-parity` branch. No Apple issue, pull request, branch publication, or push has been created. Publication remains deferred until all parity development waves are complete and explicitly authorised.

Related pull-request handoff: `docs/upstream/PR-local-driver-compression-diagnostic.md`.

<!-- markdownlint-enable MD013 -->
