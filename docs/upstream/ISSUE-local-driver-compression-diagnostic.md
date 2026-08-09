<!-- markdownlint-disable MD013 -->

# Runtime gap: local logging compression start diagnostic

## Problem

Docker Engine defers local-driver rotation validation until container start. When local compression is effective and `max-file=1`, Docker retains the created container and returns `compression cannot be enabled when max file count is 1`. Container used the json-file fallback diagnostic, `compress cannot be true when max-file is less than 2 or max-size is not set`, even though local has a concrete default maximum size and the failure is specifically the one-file policy. After the response mapping was aligned, Docker inspect still differed: the candidate returned an empty `State.Error` instead of retaining the rejected-start reason.

This affects Docker-compatible REST clients and the native authority alike. It is an upstream Container behavior gap, not a Compose parsing concern.

## Required behavior

- Preserve Docker's start-time (not create-time) validation boundary for `local` compression.
- Preserve the created container and its configured local options after the failed start.
- Emit Docker's local one-file diagnostic: `compression cannot be enabled when max file count is 1`.
- Retain the mapped rejected-start reason in Docker inspect `State.Error`, including after an authority restart, and clear it only after a successful start.
- Keep json-file's generic missing-size/one-file diagnostic unchanged.
- Retain a focused public-socket certificate for rotation, restart retention, tailing, and the invalid local start.

## Acceptance evidence

- [x] Pinned Docker Engine 29.2.1 oracle records the local one-file message, retained `created` state, and configured options.
- [x] Container's start validator selects the local-specific diagnostic only when local compression has an effective one-file policy.
- [x] The generic json-file diagnostic remains covered by the existing start-validator cases.
- [x] The public Docker CLI certificate covers compressed 4 KiB/3-file local rotation, retained history across restart, tailing, and the one-file failure.
- [x] Build the exact current local Container artifact and pass the public-socket certificate through it.
- [x] The public socket retains Docker's mapped rejected-start reason in `State.Error`.
- [ ] Execute the new authority-restart regression; its source is present and syntax-checked, but the focused Swift lane remains deferred.
- [ ] Run the focused Swift regression through a target-only build path; `swift test --filter` currently expands into the whole package graph and was stopped before test execution.

## Local evidence

Signed local checkpoints `666a99a5df004111b4addd84565a90e7c26f767d`, `9c442be1e175625425f630dba1956c2d348b6104`, and `f16b7de6ceb5ed3dd588bab08b11867a410ef346` implement the validator, Docker response mapping, and durable inspect state. The exact candidate archive built from `f16b7de6ceb5ed3dd588bab08b11867a410ef346` passed the public Docker socket certificate with Compose `c19ce0f04ba98f7bf133c753f79604885bac4747`, Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, and Engine API `4949e743675f00ec102f7acacdb4e990409e383f`. The marker-protected evidence root is `/private/tmp/container-local-rotation-evidence.6AdU7M`.

## Apple-shaped boundary

The change is retained only on the local `upstream/logging-driver-parity` branch. No Apple issue, pull request, branch publication, or push has been created. Publication remains deferred until all parity development waves are complete and explicitly authorised.

Related pull-request handoff: `docs/upstream/PR-local-driver-compression-diagnostic.md`.

<!-- markdownlint-enable MD013 -->
