<!-- markdownlint-disable MD013 -->

# Runtime gap: Docker-compatible GELF TCP retry observation on macOS

## Problem

The Docker GELF TCP driver observes peer resets and reconnects from its Linux engine context. Container's native macOS TCP path can write successfully after a peer has reset, which moves the observable failure and reconnect timing away from Docker's `gelf-tcp-max-reconnect` and non-zero `gelf-tcp-reconnect-delay` contract. The retry policy itself must remain owned by the existing `GELFSession`; moving that policy into a relay would create duplicate replay and a second authority for delivery state.

## Required behavior

- For TCP GELF only, open and write the remote socket from the protected Engine-Linux sandbox while preserving the existing session as the sole retry and replay authority.
- Keep UDP GELF on its native transport; do not broaden the guest relay into a generic networking proxy.
- Validate a sealed Linux/arm64 workload archive, its pinned build provenance, and its OCI manifest digest before it enters the provider catalog.
- Fail closed when the guest relay is unavailable, generation-mismatched, or reports a partial write; never fall back silently to macOS TCP.
- Copy the artifact to a marker-protected disposable root before a Swift acceptance test, because a local Swift test may clean generated project outputs during planning.

## Acceptance evidence

- [x] The same-MBP Docker Engine 29.2.1 / Docker CLI 29.7.1 delayed-retry oracle records two forced peer resets, a positive reconnect budget, a one-second delay, the observed ordered record disposition, inspect projection, lifecycle, and cleanup. The post-hardening retained root `/private/tmp/container-rest-gelf.default-host.wG4HQt` passed in `22.447226208s` with result SHA-256 `ecb6fc023506a605c360f4032a59a26138daa0898d3dfd2db3e1c7ac1f363abe`.
- [x] The sealed Linux/arm64 helper passes `make test-gelf-service` with `gofmt`, `go vet`, race-enabled tests, deterministic workload-manifest comparison, and 90.5% statements coverage.
- [x] The real-asset acceptance command copies the built artifact outside the generated project tree, uses its own marker-protected SwiftPM scratch path, and passes all 17 `EngineLinuxSandboxGELFTCPServiceTests` against the exact local dependency graph.
- [x] Focused provider, wire, session, partial-write, generation, asset-validation, and materialization tests pass on the local Container/Containerization/Engine API graph.
- [ ] Two independent exact-fingerprint public Docker-socket candidates match the retained Docker reference without interrupting the user-owned devcontainer engine.
- [ ] A release-build paired performance result meets the programme's comparable-or-better median/P95 rule.

## Local evidence and blocker

The current local implementation is signed Container `45bbfb00542d9d91598356ce7dd8c3c6ad2be374` on `upstream/logging-driver-parity`. Its Docker oracle and the Compose-facing contract record are retained in `/Users/sclarke/github/container-compose/docs/parity/handoffs/LOGGING-GELF-TCP-RETRY-DELAY-01.md`. The helper's real-asset acceptance run uses marker-protected `/private/tmp/container-gelf-service-swift.*` and `/private/tmp/container-gelf-service-swift-build.*` roots, validates the copied archive again after Swift execution, and runs only with the exact local Containerization `38d9c695…` and Engine API `4949e743…` overlay. The current relay archive SHA-256 is `734f01e0fdcf246626d84ef6ceb58b9ff921f12cdd6875553ac8b67dc0a10bc4` and manifest SHA-256 is `739d761b4bfed653bb0e19709762daeda7528be0c2fd7b27054f76fdeb067f91`. The checked-in remote Containerization lock lacks `WorkloadNetworkEndpoint`, so it is deliberately not represented as candidate evidence.

The public-socket candidate is deliberately not run while user-owned PID `64414` (`/opt/homebrew/opt/devcontainer/bin/devcontainer-engine`) owns the shared per-user Container launchd/XPC namespace. The isolated candidate runner invokes `container system stop`; stopping that unrelated user service would violate the runtime-lock boundary. This is a retained handoff/blocker for the candidate proof, not a claim that the full logging contract is complete.

## Apple-shaped boundary

The implementation is retained locally on `upstream/logging-driver-parity`. No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all parity development waves are complete and the user explicitly authorises coordinated upstream publication.

Related pull-request handoff: `docs/upstream/PR-gelf-tcp-engine-linux-relay.md`.

<!-- markdownlint-enable MD013 -->
