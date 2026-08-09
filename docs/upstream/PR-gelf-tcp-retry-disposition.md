<!-- markdownlint-disable MD013 -->

# Pull request handoff: align GELF TCP reset recovery disposition with Docker

## Summary

- Keep TCP GELF reconnect timing and failed-frame disposition in `GELFSession`.
- Drop the indeterminate failed write and one recovery-settlement record instead of replaying either frame.
- Bound replacement connection attempts and retain the successful replacement for later records.
- Attach the sealed Engine-Linux sandbox to the default VMNet network for protected TCP GELF egress.

## Scope

This is a narrow Docker logging compatibility correction. It does not change GELF UDP behavior, logging option parsing, route selection, generic VSOCK framing, the guest GELF workload, remote-driver configuration, migrations, release publication, or performance policy.

## Implementation

`GELFDriverSession.writeTCP` now closes a transport whose write failed, performs the existing bounded delayed reconnect, and records that the next TCP record is a recovery-settlement frame. It does not replay the write whose remote disposition is unknowable; the following write clears the settlement marker without delivery, and later writes use the already-open replacement transport. Connection failures consume the configured replacement budget and still report `reconnectAttemptsExhausted` once that budget is exhausted.

The service wire and sealed connector remain deliberately replay-free. `EngineLinuxSandboxRuntimeServiceV1` reserves the default VMNet network, converts its allocation into the sandbox interface, and retains the XPC allocation session for the shared sandbox lifetime; the direct test initializer remains network-independent.

## Docker oracle and validation

Pinned reference: Docker Engine 29.2.1 / API 1.53 with Docker CLI 29.7.1 on the programme MBP.

- The strict Docker `tcp-retry-delay` reference at `/private/tmp/container-rest-gelf.ref-diagnostic.cRVnvX` passes in `22.440267625s` and retains `first` -> `fourth` -> `after-retry-delay-complete` after two forced one-frame resets.
- Two fresh strict candidate fixture roots pass at `/private/tmp/container-rest-gelf.disposition-final.mlQOGu` (`23.912849041s`) and `/private/tmp/container-rest-gelf.disposition-final-rerun.nGfhmz` (`22.319917125s`). Each receiver reports exactly two reset peers with one frame each, terminal recovery, peer close, and no timeout.
- The complementary `tcp-failure` candidate at `/private/tmp/container-rest-gelf.failure-final.uvDlOp` passes in `13.318770666s`, with two one-frame reset peers and successful recovery.
- `GELFSessionTests` (16) and `EngineLinuxSandboxRuntimeServiceTests` (16) pass on the exact local dependency graph. `git diff --check` passes after the source change.

The Compose harness is SHA-256 `a0ed0178a62be517b42d4a21070ea73a57689513b7a623c3fcdfcdd6efc94fca`; the runtime wrapper is SHA-256 `7a396d8626a0e37c1b7f71e732674baebd1b3752bedc3378a7e4510e3323987f`; and the local source branch is `upstream/logging-gelf-tcp-readiness-02` from `c6a8663705d75180241232cb99442fbac4f8a6ac` with local Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API `afb8a8f68ed56829b669c95cbddb488a68dc9175`.

## Performance and risk

The focused candidate delay durations are 1.07x and 0.99x of Docker. This is evidence only: the programme defers performance optimization until the full functional surface is complete. A timeout or hang remains a functional blocker; none occurred in the retained runs. The existing isolated candidate uses a debug build, so these runs are not a release performance certificate.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all parity development waves are complete and the user explicitly authorises the coordinated Apple upstream wave.

Related issue handoff: `docs/upstream/ISSUE-gelf-tcp-retry-disposition.md`.

<!-- markdownlint-enable MD013 -->
