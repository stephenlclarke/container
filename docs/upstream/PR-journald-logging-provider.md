# Pull request: add a Docker-compatible journald provider contract

> [!IMPORTANT]
> This handoff remains local until the complete parity programme is ready for
> coordinated Apple publication. The production Linux journald service is a
> required follow-up before the driver can be advertised as supported.

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
  writer/sandbox generation, and reader open resumes at the durable sequence.
- Return the durable reader sequence in the open-reader wire response so a
  reconstructed client cannot restart at sequence one and duplicate history.
- Register configuration and the provider in the built-in authority plane only
  when a concrete service is supplied.

## Required follow-up before support can be claimed

- Implement and package the signed Linux journald workload and bind its vsock
  listener to the completed connection/handler engine.
- Implement the concrete systemd adapter behind the durable backend. Append
  must reconcile the complete session/epoch/ordinal identity, and reads must be
  deterministic for an identical request/sequence across state-save failure.
- Implement journal query ordering and Docker filters for stdout/stderr,
  follow, tail, since, until, timestamps, and details.
- Route authority-owned provider readers through the production reader plane.
- Add service supervision, readiness withdrawal, bounded transport, security,
  migration, and shutdown behavior.
- Certify real-systemd integration and Docker CLI/Compose behavior, then record
  throughput, latency, memory, and backpressure evidence against Docker.

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
  close fencing, reader resume/replay, generation matching, private file modes,
  and symbolic-link rejection.

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
make check
git diff --check
```

Current development MacBook Pro evidence:

- five journald provider tests and three built-in provider-set tests passed;
- five journald wire tests passed, including exact replay and cancellation;
- seven journald wire-server tests passed, including concurrent replay-cache
  and end-to-end framed-connection cases;
- seven durable-backend tests passed, covering both append/state crash windows,
  no-duplicate recovery, close/write reentrancy fencing, active-reader
  generation checks, durable reader resume, and private file-store hardening;
- the combined journald wire, server, and durable-backend filter passed all 19
  tests with Swift warnings promoted to errors;
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
  fences close-before-flush, and resumes the exact reader sequence.
- [ ] Add the signed Linux service and concrete systemd journal adapter.
- [ ] Complete production reader routing, recovery, and supervision.
- [ ] Add real-systemd compatibility and performance evidence.

Related issue handoff: `docs/upstream/ISSUE-journald-logging-provider.md`.
