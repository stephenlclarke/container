# Pull request: add a Docker-compatible journald provider contract

> [!IMPORTANT]
> This handoff remains local until the complete parity programme is ready for
> coordinated Apple publication. The Linux workload and concrete systemd
> adapter are implemented and packaged locally, but production supervision,
> release signing, authority routing, and readiness-gated advertisement remain
> required before the driver can be advertised as supported.

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
- Register configuration and the provider in the built-in authority plane only
  when a concrete service is supplied.

## Required follow-up before support can be claimed

- Add the authority-owned supervisor that verifies the expected OCI workload
  digest, installs its private journal/state mounts, starts it inside the
  common Engine Linux sandbox, authenticates the exact generation, and
  withdraws readiness on process, journal, or transport failure.
- Route production writer and reader sessions through that supervised service,
  reconcile service/sandbox restart without overlapping writers, and advertise
  `journald` only for the exact ready provider generation.
- Add authority-driven reclamation for terminal service writer/reader state so
  the bounded durable replay window cannot become a lifetime session quota;
  complete delete, migration, shutdown, and recovery behavior.
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

## Code map

- `Sources/ContainerLoggingProviders/Journald/JournaldConfiguration.swift`
  contains the Docker option and field codec.
- `Sources/ContainerLoggingProviders/Journald/JournaldProvider.swift` contains
  the descriptor, service boundary, session lifecycle, fencing, and reader
  provider.
- `Sources/ContainerLoggingProviders/Journald/JournaldServiceWire.swift`
  contains the bounded versioned request/response projections, framed socket
  codec, reconnect-safe transport, and service client.
- `Sources/ContainerLoggingProviders/Journald/JournaldServiceServer.swift`
  contains the bounded exact-once replay engine, backend boundary, failure
  mapping, and persistent framed connection loop.
- `Sources/ContainerLoggingProviders/Journald/JournaldServiceDurableBackend.swift`
  contains the bounded restart snapshot, private atomic file store,
  save-before-publish transitions, writer reconciliation/fencing, reader
  resume, and system-journal adapter boundary.
- `Sources/ContainerLoggingProviders/BuiltinRemoteLogDriverProviderSet.swift`
  stores typed bindings and conditionally installs the provider.
- `Sources/Services/ContainerAPIService/Server/Containers/AuthorityRemoteLogDriverPlane.swift`
  resolves the exact configuration and selected sandbox generation.
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

- five journald provider tests and three built-in provider-set tests passed;
- five journald wire tests passed, including exact replay and cancellation;
- seven journald wire-server tests passed, including concurrent replay-cache
  and end-to-end framed-connection cases;
- eight durable-backend tests passed, covering both append/state crash windows,
  no-duplicate recovery, close/write reentrancy fencing, active-reader
  generation checks, durable reader checkpoint resume, invalid/stalled
  checkpoint rejection, and private file-store hardening;
- the combined journald wire, server, and durable-backend filter passed all 20
  tests;
- 17 portable Go service tests passed with the race detector; the pinned Linux
  real-systemd lane passed all 20 tests, including exact append replay/conflict,
  static/follow reads, cancellation, fixed resource bounds, and durable
  checkpoint recovery;
- two independently built OCI archives produced the same Linux/arm64 workload
  manifest digest
  `sha256:90238651d604cc14f93477cfbf7ca4c50ca7cc36ab416553d05e03c6d7ec1c2a`;
  the final archive and its recorded source/test hashes verified;
- the packaged Swift-to-Linux integration passed its real-systemd stdout/stderr
  round trip and removed its temporary dependency edit, image, containers, and
  volumes;
- direct component baselines on this MacBook Pro measured protocol replay at
  1.75–2.09 microseconds, durable writer commit at 38.7–51.5 microseconds, and
  query-visible systemd append at 11.43–11.66 milliseconds across three runs;
- provider and API server targets built successfully;
- the provider and API server targets built with Swift warnings promoted to
  errors;
- formatting, licence, and whitespace gates passed;
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

The warnings-as-errors build used the local signed Containerization
shared-sandbox worktree because the coordinated Containerization upstream wave
has not been published. SwiftPM editable state was removed afterward; the
published dependency pin remains unchanged.

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
- [x] Add the Linux service, concrete systemd journal adapter, pinned OCI build,
  and cross-language real-systemd evidence.
- [ ] Complete production reader routing, recovery, and supervision.
- [ ] Add release signing and readiness-gated installation/advertisement.
- [ ] Add paired Docker compatibility and performance evidence.

Related issue handoff: `docs/upstream/ISSUE-journald-logging-provider.md`.
