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
- Register configuration and the provider in the built-in authority plane only
  when a concrete service is supplied.

## Required follow-up before support can be claimed

- Implement and package the signed Linux journald workload, bounded
  journald-specific wire protocol, and systemd journal adapter on the completed
  shared-sandbox dial.
- Persist writer identity/epoch state and reconcile service or authority crash,
  response loss, and sandbox replacement.
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
- `Sources/ContainerLoggingProviders/BuiltinRemoteLogDriverProviderSet.swift`
  stores typed bindings and conditionally installs the provider.
- `Sources/Services/ContainerAPIService/Server/Containers/AuthorityRemoteLogDriverPlane.swift`
  resolves the exact configuration and selected sandbox generation.
- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxServiceRuntime.swift`
  and `EngineLinuxSandboxRuntimeClient.swift` provide the generation-fenced
  XPC/vsock connection to a protected service.
- `Tests/ContainerLoggingProvidersTests/JournaldProviderTests.swift` covers the
  pinned codec and lifecycle contract.

## Validation

```console
swift build --target ContainerLoggingProviders
swift build --target container-apiserver
swift test --filter JournaldProviderTests
swift test --filter BuiltinRemoteLogDriverProviderSetTests
swift build -Xswiftc -warnings-as-errors --target container-apiserver
make check
git diff --check
```

Current development MacBook Pro evidence:

- five journald provider tests and three built-in provider-set tests passed;
- provider and API server targets built successfully;
- the API server target built with Swift warnings promoted to errors;
- formatting, licence, and whitespace gates passed;
- signed implementation commit:
  `887848ed719a05836d2f846b69a22749e61f2f62`.
- signed shared-service transport commit:
  `20071d97d10b386c2a24c84c51bca0e37c0280aa`.

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
- [ ] Add the signed Linux service and persistent journal adapter.
- [ ] Complete production reader routing, recovery, and supervision.
- [ ] Add real-systemd compatibility and performance evidence.

Related issue handoff: `docs/upstream/ISSUE-journald-logging-provider.md`.
