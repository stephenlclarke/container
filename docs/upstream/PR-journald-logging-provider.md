# Pull request: add a Docker-compatible journald provider contract

> [!IMPORTANT]
> This handoff remains local until the complete parity programme is ready for
> coordinated Apple publication. The Linux workload is now verified,
> materialized, supervised, routed, readiness-gated, and reclaimed by the
> production authority. Release trust publication, dependency-pin
> synchronization, and paired Docker compatibility/performance certification
> remain required before programme-wide support can be claimed.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The API authority already owns logging-provider selection, protected effects,
runtime pipes, delivery buffering, and generation fencing. Journald additionally
requires a Linux-local system-journal service because the macOS authority cannot
write or query the guest journal directly.

The option, field, partial-message, priority, and read semantics are pinned to
Moby 29.2.1. Provider publication is fail-closed: no `JournaldService` means no
catalog descriptor and no false compatibility claim.

## Implemented in this slice

- Add Docker-compatible option resolution, template and RE2 delegation,
  environment-over-label precedence, and exact Moby field-name sanitization.
- Encode container/image/tag/syslog metadata, stdout/stderr priorities,
  RFC3339Nano timestamps, partial metadata, and per-writer epoch/ordinal fields
  in a binary-safe service request.
- Project service records to direct native reads without adding a newline to an
  incomplete partial message.
- Add generation-fenced, effect-token-protected, idempotent writer and reader
  provider lifecycles.
- Define the narrow signed Linux-service boundary for generation discovery,
  writer open/write/flush/close, and reader open.
- Add the generic shared-sandbox XPC/vsock dial used to reach a protected
  service only after independently checking the exact durable generation in
  the API authority and runtime helper.
- Add the journald-specific one-MiB framed protocol and client, with explicit
  versioned envelopes, validated binary-safe entries, stable operation IDs,
  ordered reader-next calls, one reconnect replay, mismatched-response
  rejection, `SIGPIPE` suppression, and cancellation-safe socket shutdown.
- Add the server protocol engine and persistent connection loop. Identical
  in-flight operations join one backend effect, completed outcomes replay from
  a count- and encoded-byte-bounded cache, conflicting operation-ID reuse fails
  before an effect, and backend failures map to stable wire categories.
- Add the restart-safe backend and private atomic state store. Writer
  session/epoch/ordinal identity survives service restart, a pending append is
  reconciled without duplication, uncertain state persistence requires reload,
  every close fences new writes before flush, active readers validate the exact
  writer/sandbox generation, and reader open resumes at the durable sequence
  and bounded adapter-private journal checkpoint.
- Prepare the native journal position before publishing a reader open, advance
  that checkpoint atomically with each record, and fail closed if a record
  stalls the position or an end event mutates it. This removes dependence on a
  process-local systemd cursor after service restart.
- Advance the private snapshot schema to version two and reject sequence-only
  version-one snapshots; accepting one would invent a native journal position
  and could duplicate or skip a record.
- Return the durable reader sequence in the open-reader wire response so a
  reconstructed client cannot restart at sequence one and duplicate history.
- Add a Linux/arm64 service executable with a production AF_VSOCK listener,
  exact sandbox-generation handshake, bounded connections, disconnect-driven
  operation cancellation, and a test-only private Unix listener.
- Add the concrete go-systemd adapter. Append reconciliation queries the full
  session/epoch/ordinal identity and entry digest before publishing, and does
  not acknowledge a new entry until it is query-visible. Native reads preserve
  receipt order, stdout/stderr, tail, since, until, follow, details, partial
  records, and opaque cursor/realtime/end checkpoints.
- Bound replay memory by retained request and response bytes, replace
  attacker-controlled session-lock maps with fixed domain-separated stripes,
  cap durable writer/reader state, and interrupt blocked Linux operations when
  the client connection disappears.
- Package the service and its dedicated systemd-journald process as a pinned
  Linux/arm64 OCI workload. The build records source/test hashes, the archive
  hash, and the stable platform-manifest digest, uses a signed Debian snapshot
  for exact systemd packages, and emits BuildKit provenance.
- Add portable race/unit tests, real-systemd integration and component
  benchmarks, deterministic workload-manifest verification, and an opt-in
  Swift-to-packaged-Linux cross-language test that verifies an exact
  stdout/stderr write/read round trip.
- Compose the production API server with the shared-sandbox launchd authority
  and a lazy journald service. Verify the installed manifest and OCI archive,
  load only the recorded Linux/arm64 manifest digest, materialize a read-only
  workload, and mount separate protected service-state and persistent-journal
  directories.
- Bind every service dial to the exact sandbox ID/generation, workload ID,
  process generation, and vsock port. Monitor terminal workload exit, withdraw
  the retained running receipt immediately, and permit exact rematerialization
  only after terminal state is observed.
- Probe the concrete service generation before returning the logging-driver
  catalog, so `journald` is advertised only while the exact service is ready
  and is dynamically withdrawn on process, journal, transport, or generation
  failure.
- Advance the wire/service contract to protocol version two and add
  authority-ordered terminal writer/reader reclamation. The lifecycle ledger
  commits terminal state before asking the provider to reclaim, then removes
  the protected effect; interrupted removals replay idempotently on startup.
- Preserve exact replay across a same-generation service restart, but validate
  and atomically reset protocol sessions when the sandbox generation advances.
  Persistent journal storage remains mounted across that rollover.
- Add builder bootstrap, package/Homebrew staging, manifest/archive integrity
  verification, deterministic multi-build checks, Go race tests, and the
  Swift-to-packaged-Linux integration to the release build surface.

## Required follow-up before programme-wide support can be claimed

- Add release signing and installation verification around the reproducible
  OCI workload and its BuildKit provenance. A signed source commit and recorded
  platform digest are development evidence, not a production release trust
  chain.
- Synchronize the Container dependency pin with the matched Containerization
  protected-workload API before publishing either repository. The current pin
  predates `WorkloadNetworkEndpoint`, so local validation intentionally uses
  SwiftPM editable state and removes it afterward.
- Certify Docker CLI/Compose behavior and record the paired warmed/cold
  throughput, latency, CPU, memory, startup, follow, and backpressure evidence
  against the pinned Docker reference. The current real-systemd/component
  measurements are baselines, not a parity-performance claim.
- Complete the separate isolated Docker logging-plugin service plane. The
  journald worker deliberately does not host third-party Docker plugins.
- Exercise programme-level install/upgrade/rollback and whole-stack shutdown
  under the final signed dependency set. The provider's own restart,
  generation rollover, terminal reclamation, and response-loss paths are now
  implemented and covered locally.

## Code map

- `Sources/ContainerLoggingProviders/Journald/JournaldConfiguration.swift`
  contains the Docker option and field codec.
- `Sources/ContainerLoggingProviders/Journald/JournaldProvider.swift` contains
  the descriptor, service boundary, session lifecycle, fencing, terminal
  reclamation, and reader provider.
- `Sources/ContainerLoggingProviders/Journald/JournaldServiceWire.swift`
  contains the bounded versioned request/response projections, framed socket
  codec, reconnect-safe transport, and service client.
- `Sources/ContainerLoggingProviders/Journald/JournaldServiceServer.swift`
  contains the bounded exact-once replay engine, backend boundary, failure
  mapping, and persistent framed connection loop.
- `Sources/ContainerLoggingProviders/Journald/JournaldServiceDurableBackend.swift`
  contains the bounded restart snapshot, private atomic file store,
  save-before-publish transitions, writer reconciliation/fencing, reader
  resume, terminal reclamation, safe sandbox-generation rollover, and
  system-journal adapter boundary.
- `Sources/ContainerLoggingProviders/BuiltinRemoteLogDriverProviderSet.swift`
  stores typed bindings and conditionally installs the provider.
- `Sources/Services/ContainerAPIService/Server/Containers/AuthorityRemoteLogDriverPlane.swift`
  resolves the exact configuration and selected sandbox generation, recovers
  pending terminal effects, and readiness-filters the catalog.
- `Sources/Services/ContainerAPIService/Server/Containers/EngineLinuxSandboxJournaldService.swift`
  verifies installed assets, materializes the exact protected workload and
  durable mounts, supervises it through the shared-sandbox authority, and
  opens an exact-generation service connection.
- `Sources/APIServer/APIServer+Start.swift` conditionally composes that
  production service and leaves `journald` unadvertised if its installed or
  runtime prerequisites cannot be established.
- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxServiceRuntime.swift`
  and `EngineLinuxSandboxRuntimeClient.swift` provide the generation-fenced
  XPC/vsock connection to a protected service.
- `Tests/ContainerLoggingProvidersTests/JournaldProviderTests.swift` covers the
  pinned codec and lifecycle contract.
- `Tests/ContainerLoggingProvidersTests/JournaldServiceWireTests.swift` covers
  frame and entry limits, binary round trips, lifecycle projection, exact
  response-loss replay, reader ordinals, and blocked-read cancellation.
- `Tests/ContainerLoggingProvidersTests/JournaldServiceServerTests.swift`
  covers lifecycle projection, concurrent duplicate joining, completed replay,
  conflict rejection, bounded eviction, stable failures, and end-to-end
  persistent framed client/server calls.
- `Tests/ContainerLoggingProvidersTests/JournaldServiceDurableBackendTests.swift`
  covers restart reconciliation, uncertain state-save recovery, ordering and
  close fencing, reader checkpoint resume/replay, stalled/invalid checkpoint
  rejection, generation matching, private file modes, and symbolic-link
  rejection.
- `Tools/ContainerJournaldService/` contains the strict Go wire server, durable
  backend, concrete systemd adapter, AF_VSOCK executable, dedicated journald
  entrypoint, pinned OCI recipe, build/verification harness, and unit,
  integration, cancellation, resource-bound, and benchmark coverage.
- `Tests/ContainerLoggingProvidersTests/JournaldServiceLinuxIntegrationTests.swift`
  exercises the production Swift client against the packaged Linux workload
  and real system journal.

## Validation

```console
swift build --target ContainerLoggingProviders
swift build --target container-apiserver
swift test --filter JournaldProviderTests
swift test --filter JournaldServiceWireTests
swift test --filter JournaldServiceServerTests
swift test --filter JournaldServiceDurableBackendTests
swift test --filter JournaldService
swift test --filter BuiltinRemoteLogDriverProviderSetTests
swift build -Xswiftc -warnings-as-errors --target ContainerLoggingProviders
swift build -Xswiftc -warnings-as-errors --target container-apiserver
make test-journald-service
make verify-journald-service
make test-journald-service-integration
make check
git diff --check
```

Current development MacBook Pro evidence:

- the current warnings-as-errors journald run passed all 31 tests in six
  suites, including provider reclamation, exact wire operations, durable
  backend generation rollover, installed-asset verification, and production
  materialization/connection behavior;
- the Engine Linux sandbox runtime/authority filter passed all 14 tests, and
  its Thread Sanitizer run passed without a race report;
- portable Go unit/integration coverage passed with the race detector,
  including active/mismatched reclaim rejection, idempotent terminal reclaim,
  restart replay, session-ID reuse, and sandbox-generation reset;
- deterministic multi-build verification produced Linux/arm64 workload
  manifest digest
  `sha256:9e3ab273aa26ba6bb62d6905b4034451b19d42964592e673197242bd05638841`;
  the final OCI archive SHA-256
  `e391eb6f62570f2ea41b04185c3f01ed6a736f2376b833b6854952314e18ad0d`
  and recorded source/test hashes verified;
- the packaged Swift-to-Linux integration passed its real-systemd stdout/stderr
  round trip and removed its temporary dependency edit, containers, and
  volumes;
- direct component baselines on this MacBook Pro measured protocol replay at
  1.75–2.09 microseconds, durable writer commit at 38.7–51.5 microseconds, and
  query-visible systemd append at 11.43–11.66 milliseconds across three runs;
- debug release staging installed the current protocol-v2 OCI archive and
  manifest under the journald service install root;
- `make check`, Bash syntax, ShellCheck, formatting, licence, and whitespace
  gates passed;
- signed production supervision/reclamation commit:
  `84d160671f3ba6c265a02b49b2ff4309f6584d30`.
- signed implementation commit:
  `887848ed719a05836d2f846b69a22749e61f2f62`.
- signed shared-service transport commit:
  `20071d97d10b386c2a24c84c51bca0e37c0280aa`.
- signed journald service-wire commit:
  `a42ecf2fe1ffa582e34cfa74f6cf1ddba8505368`.
- signed journald wire-server commit:
  `bed5de1686bc005ad77ab63025a5582f37601738`.
- signed journald durable-backend commit:
  `79c89babc7399c0cc1d4f800bd5ec092cc6c153d`.
- signed durable reader-checkpoint commit:
  `dcefedba2b3b5806953c32e35ca2edaea24658a0`.
- signed Linux workload/systemd-adapter commit:
  `e8cc75f001d24896144a5e44e33d1f7a5d1e5729`.

The current warnings-as-errors and packaged-integration builds used the local
signed Containerization shared-sandbox worktree because the coordinated
Containerization upstream wave has not been published. SwiftPM editable state
was removed afterward; `Package.resolved` and the published dependency pin
remain unchanged.

## Review checklist

- [x] Moby-compatible option and field semantics are explicit and tested.
- [x] Writer and reader lifecycles are idempotent and generation-fenced.
- [x] Journald is absent from the catalog without a concrete service.
- [x] The production API server does not advertise an unavailable driver.
- [x] The protected service connection is generation-fenced in both the API
  authority and runtime helper.
- [x] The client wire is versioned, size-bounded, reconnect-safe, and preserves
  exact operation identity and reader order across response loss.
- [x] The server joins in-flight replay, caches bounded outcomes, rejects
  conflicting identities before effects, and serves persistent framed calls.
- [x] Durable writer/reader state reconciles restart and response-loss windows,
  fences close-before-flush, and resumes the exact reader sequence and native
  journal checkpoint.
- [x] The Linux service, concrete systemd journal adapter, pinned OCI build,
  and cross-language real-systemd evidence.
- [x] Production writer/reader routing, exact workload supervision,
  readiness-gated advertisement, terminal reclamation, and generation rollover
  are implemented.
- [ ] Add release-signature trust publication and synchronized dependency pins.
- [ ] Add paired Docker compatibility and performance evidence.

Related issue handoff: `docs/upstream/ISSUE-journald-logging-provider.md`.
