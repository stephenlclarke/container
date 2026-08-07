<!-- markdownlint-disable MD013 -->

# Pull request handoff: relay TCP GELF through Engine Linux

## Summary

- Add a sealed Linux/arm64 GELF TCP relay that owns only the outbound guest socket.
- Preserve `GELFSession` as the one reconnect-delay and frame-replay authority.
- Inject the relay only for TCP GELF, retain native UDP delivery, and fail closed when the relay cannot be used.
- Package and verify the workload archive and manifest, including an isolated real-asset acceptance target that is safe from local Swift output cleanup.

## Scope

This is a narrow Container logging-runtime compatibility change. It does not alter Compose option parsing, Docker Engine route projection, GELF UDP semantics, general guest networking, generic TCP proxying, logging plug-ins, migrations, external clients, or release publication.

## Implementation

`GELFTCPServiceWireV1` defines a bounded, versioned VSOCK protocol for generation, open, write, and close operations. The protected Linux workload validates one request at a time, maps `host.docker.internal` to the guest default IPv4 gateway, and exposes Docker-relevant connection, timeout, and write failures without replaying frames.

`EngineLinuxSandboxGELFTCPServiceV1` verifies the installed OCI archive and manifest, loads the exact pinned Linux/arm64 image, materializes a read-only host-network workload with protected tmpfs mounts, verifies the active sandbox generation, and dials its VSOCK service. A partial remote write becomes a failed guest response and a partial service receipt invalidates the client transport, so the existing GELF session owns recovery.

The provider set receives the service by dependency injection. APIServer initialization supplies the Engine-Linux service lazily and reports an unavailable service as a TCP GELF failure rather than falling back to a macOS TCP socket. The Makefile packages the archive under `libexec/container/services/gelf` and verifies it before installer and Homebrew artifacts are created.

`test-gelf-service-asset` copies the archive and manifest to a marker-protected `/private/tmp` root before it invokes the real Swift materializer acceptance test, and gives SwiftPM a separate marker-protected scratch path. This keeps the focused test independent from both generated-output cleanup and stale instrumentation in another build root while preserving manifest verification after execution.

## Docker oracle and validation

Pinned Docker reference: Docker Engine 29.2.1 / API 1.53 with Docker CLI 29.7.1 and Alpine 3.20 on this MBP. The post-hardening retained root `/private/tmp/container-rest-gelf.default-host.wG4HQt` passed the Compose fixture `tcp-retry-delay` in `22.447226208s` (result SHA-256 `ecb6fc023506a605c360f4032a59a26138daa0898d3dfd2db3e1c7ac1f363abe`), forcing two peer resets with `gelf-tcp-max-reconnect=2` and `gelf-tcp-reconnect-delay=1`; it verifies the Docker-observed delayed-retry record disposition, metadata, inspect state, authority, and cleanup.

- Signed Container `45bbfb00542d9d91598356ce7dd8c3c6ad2be374` carries the implementation; `make test-gelf-service` passes the Linux helper's `gofmt`, `go vet`, race, deterministic-manifest, and 90.5% coverage gate.
- The exact local-graph copied-asset command passes all 17 `EngineLinuxSandboxGELFTCPServiceTests`; it verifies the copied archive after execution and leaves no shared SwiftPM build state.
- `GELFTCPServiceWireTests` (8), `EngineLinuxSandboxGELFTCPServiceTests` (17), provider-set TCP injection (7), and `GELFSessionTests` (16) cover injection, protocol validation, no-fallback behavior, partial-write handling, asset provenance, sandbox generation, stale-service identity, and retry ownership.
- `git diff --check`, `bash -n`, `shellcheck`, and focused Swift formatting checks pass at the local checkpoint.

The public candidate remains safely handed off: its isolated runner would stop user-owned PID `64414` (`devcontainer-engine`) in the shared Container namespace. A later runtime run must first receive explicit approval to quiesce or isolate that service, then use an exact source/dependency/binary/guest/root fingerprint and two independent marker-protected candidate roots. The programme-wide comparable-or-better performance requirement is also still open.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all parity development waves are complete and the user explicitly authorises the coordinated Apple upstream wave.

Related issue handoff: `docs/upstream/ISSUE-gelf-tcp-engine-linux-relay.md`.

<!-- markdownlint-enable MD013 -->
