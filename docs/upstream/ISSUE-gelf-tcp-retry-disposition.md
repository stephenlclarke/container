<!-- markdownlint-disable MD013 -->

# Runtime gap: Docker GELF TCP reset recovery frame disposition

## Problem

After a GELF TCP peer reset, Container replayed the failed record on its replacement socket. The strict Docker Engine 29.2.1 oracle proves that Docker instead treats that write as indeterminate, prepares a delayed replacement connection, drops both the failed record and the first recovery-settlement record, then resumes ordinary delivery. Container also needed to keep the shared Engine-Linux sandbox attached to a reserved VMNet egress interface so the protected relay could reach `host.docker.internal` at all.

## Required behavior

- Keep a single `GELFSession` responsible for bounded reconnect timing and frame disposition; the VSOCK service must never add another replay loop.
- After a failed TCP write, establish at most the configured replacement attempts, do not replay the indeterminate failed record, and omit one subsequent recovery-settlement record before normal delivery resumes.
- Retain the replacement transport for later records and preserve the existing cancellation, partial-write, zero-budget, and reconnect-exhaustion behavior.
- Reserve and retain the default VMNet attachment for the lifetime of the sealed shared sandbox, so protected TCP GELF egress is Docker-observable.

## Acceptance evidence

- [x] `GELFSessionTests` passes 16 focused tests against local Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API `afb8a8f68ed56829b669c95cbddb488a68dc9175`; regressions cover failed-frame and recovery-settlement dropping plus bounded reconnect exhaustion.
- [x] `EngineLinuxSandboxRuntimeServiceTests` passes 16 focused tests, including the VMNet interface installation boundary.
- [x] Docker Engine 29.2.1 strict `tcp-retry-delay` oracle passes in `22.440267625s` at `/private/tmp/container-rest-gelf.ref-diagnostic.cRVnvX` and records Docker's `first` -> `fourth` -> `after-retry-delay-complete` disposition.
- [x] Two independent strict public-socket candidate runs pass in `23.912849041s` and `22.319917125s` at `/private/tmp/container-rest-gelf.disposition-final.mlQOGu` and `/private/tmp/container-rest-gelf.disposition-final-rerun.nGfhmz`; both force two single-frame resets, complete terminal recovery, and do not time out.
- [x] The complementary public-socket `tcp-failure` scenario passes in `13.318770666s` at `/private/tmp/container-rest-gelf.failure-final.uvDlOp`.

## Local evidence

The retained candidate uses the same-MBP Compose fixture `Tools/parity/check-docker-rest-gelf-contract.sh` at SHA-256 `a0ed0178a62be517b42d4a21070ea73a57689513b7a623c3fcdfcdd6efc94fca`, runtime wrapper SHA-256 `7a396d8626a0e37c1b7f71e732674baebd1b3752bedc3378a7e4510e3323987f`, and local Container branch `upstream/logging-gelf-tcp-readiness-02` from base `c6a8663705d75180241232cb99442fbac4f8a6ac`. The guest GELF service remains the verified asset from that base; this correction changes the host session and VMNet runtime wiring.

The candidate delay runs are 1.07x and 0.99x of the current Docker oracle. Those raw values are retained for later performance work; no performance optimization is a functional blocker. The earlier candidate runtime hit a bounded launchd failure while macOS had insufficient disk capacity to complete its candidate-only Keychain trust-registry transaction. Reclaiming only regenerable SwiftPM cache restored normal engine startup; the final engine remained running and all three public fixture runs completed within their 90-second bound.

## Apple-shaped boundary

The implementation is retained locally on `upstream/logging-gelf-tcp-readiness-02`. No Apple issue, pull request, branch publication, or push has been created. Do not publish it until all programme development waves are complete and the user explicitly authorises coordinated upstream publication.

Related pull-request handoff: `docs/upstream/PR-gelf-tcp-retry-disposition.md`.

<!-- markdownlint-enable MD013 -->
