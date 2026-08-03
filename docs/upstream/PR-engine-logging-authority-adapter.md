# Pull request handoff: connect Engine logs to the Container authority

## Summary

- Add an enhanced Docker logging backend over the existing
  `ContainersService` catalog, durable configuration, protected-option store,
  canonical readers, and active runtime generation.
- Add a separate lossless, bounded runtime read-record stream for Docker
  details and nanosecond presentation without breaking native compatibility.
- Bridge Docker attach to either that canonical replay/follow reader or the
  exact init-process pipes, with Docker detach keys and canonical lifecycle
  events.
- Expose hijack and WebSocket attach through the same canonical session, and
  map Docker terminal resize onto the exact init process with compatible error
  responses.
- Compose complete Docker `SystemInfo` and `ContainerInspect` documents from
  the same authority, then overlay only logging-owned fields through the
  runtime-neutral fail-closed contract.
- Start one restart-stable enhanced provider session and advertise the complete
  `ContainerAttach`, `ContainerAttachWebsocket`, `ContainerResize`,
  `ContainerLogs`, `ContainerInspect`, and `SystemInfo` generated Engine
  operations.

## Type of change

- [x] Generic Container runtime transport
- [x] API-service authority adapter
- [x] Engine private provider session
- [x] Docker logging REST/streaming projection
- [x] Protected-option authentication
- [x] Unit and provider-session integration tests
- [ ] Public Engine listener installation
- [x] Complete `/info` and inspect route composition
- [x] Attach/hijack route advertisement
- [x] WebSocket attach and terminal-resize route advertisement
- [ ] Compose parser behavior

## Authority contract

`ContainerDockerLoggingBackend` delegates to the same `ContainersService`
actor used by native clients. System info requeries the injected catalog;
inspect reads the immutable resolved driver and safe options, authenticates any
protected object with its container-bound binding, and exposes `LogPath` only
for the canonical public json-file store. No independent catalog, file reader,
or provider state is constructed by the Engine adapter.

Stopped/static reads use `ContainerLogNativeReaderFactory`. Active follow uses
the exact runtime client's retained logging generation. The new
`ContainerLogReadRecordWireV1` is an explicit transport codec rather than a
generic persistence conformance: decode reconstructs and validates the core
record, and the stream enforces a fixed encoded-record bound. Stream, exact
seconds/nanoseconds, binary payload, attributes, sequence, and process
generation cross the XPC file-descriptor boundary losslessly.

Attach uses the same reader with `follow` for readable drivers, so historical
replay and the retained active generation remain one ordered source. Drivers
without a reader, including `none`, fall back to exact-process output without
inventing historical bytes. Requested live stdin/stdout/stderr are attached
through the existing `ContainersService` runtime path. TTY output is merged;
non-TTY output retains Docker stdout/stderr channels.

`ContainerDockerAttachSession` exposes a bounded hijack frame stream. A full
buffer retries the same frame and applies backpressure instead of dropping it.
It consumes the Docker default or requested detach sequence, closes readers
and file handles exactly once across success, failure, disconnect, and runtime
attachment failure, and publishes ordered `attach`/`detach` records through
the canonical service event broadcaster.

The gateway WebSocket transport consumes that same
`ContainerDockerAttachSession`; it does not create a second reader or runtime
attachment. `ContainerDockerLoggingBackend` also implements the narrow
terminal-resize contract by validating Docker's unsigned dimensions exactly,
mapping them to Containerization's terminal size, and resizing the init
process through `ContainersService`. Missing, stopped, and out-of-range cases
retain Docker-compatible status and message semantics.

## Provider identity and route gating

`container-apiserver` loads or creates one provider-owned state-root UUID,
builds an enhanced `container-authority` declaration from Container and
Containerization revisions plus exact Engine API release 0.3.4, and starts a
private singleton provider socket. Cancellation shuts the provider down.

The fingerprint advertises `engine.route.ContainerAttach`,
`engine.route.ContainerAttachWebsocket`, `engine.route.ContainerResize`,
`engine.route.ContainerLogs`, `engine.route.ContainerInspect`, and
`engine.route.SystemInfo`. Inspect and info use the same selected Container
authority for the complete base document and the logging overlay. The shared
controller rejects a base missing any non-optional Moby top-level response
field, so a logging fragment cannot masquerade as a whole route. The common
gateway owns WebSocket framing and Docker ping negotiation; those concerns do
not create a second provider authority.

Container persists effective runtime state but not every original Docker
request distinction. The response therefore reports the truthful effective
projection and keeps original Entrypoint-versus-Cmd provenance, durable restart
count, complete health history, and unavailable endpoint/path identities as
explicit later lifecycle/API work; it does not invent those values as parity
evidence.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainerDockerLoggingBackend.swift`
  contains the neutral backend, direct and active-wire readers, runtime attach
  bridge, detach filter, and bounded hijack session.
- `Sources/Services/ContainerAPIService/Server/Containers/ContainerDockerSharedResponseBackend.swift`
  constructs the complete authority-owned system and inspect documents.
- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  exposes the narrow authority projections and exact reader selection.
- `Sources/ContainerResource/Container/ContainerLogReadRecordWireV1.swift`
  defines the explicit lossless runtime codec.
- `Sources/Services/Runtime/RuntimeClient/RuntimeRoutes.swift` and
  `RuntimeClient.swift` expose the distinct active read-record route.
- `Sources/Services/RuntimeLinux/Server/ContainerLogReaderStream.swift` and
  `RuntimeService.swift` encode the exact retained generation.
- `Sources/APIServer/APIServer+Start.swift` composes the stable enhanced
  provider session.
- Focused tests cover canonical static reads, protected inspect options,
  lossless active wire, stream cancellation, runtime I/O, detach keys,
  over-capacity no-drop behavior, provider hijack forwarding, and lifecycle
  event ordering.

## Dependency handoff

Container pins `container-engine-api` exactly at 0.3.4, signed revision
`73cef37b3693e3fc1acd650782ee7b449ab65b92`. Validation uses the local signed
Containerization shared-sandbox worktree because the coordinated
Containerization upstream wave has not been published. The build embeds the
published Containerization source and revision while compiling that matched
local work. SwiftPM editable state is removed after validation; the published
Containerization pin remains unchanged at
`77f06d4c44341e04241941072fb69e2b85a6f5c1`.

No Apple issue, pull request, branch publication, or push has been created.
The complete change remains local until all parity development is complete.

## Validation

```console
swift build --target ContainerAPIService
swift build --target container-apiserver
swift test --filter 'ContainerDockerAttachSessionTests|engineLoggingBackendUsesAuthoritativeInspectionAndExactReader'
swift test --filter 'ContainerLogReaderStreamTests|ContainerLogsTests.engine|ContainerLoggingAuthorityIntegrationTests.engineInspect'
swift test --filter 'ContainerLogsTests|ContainerDockerAttachSessionTests'
swift test --skip-build -c debug \
  -Xswiftc -warnings-as-errors -Xswiftc -enable-testing \
  --no-parallel --skip TestCLI --skip IntegrationTests
make check
git diff --check
```

Current development MacBook Pro evidence:

- Container API service and APIServer targets build against the local signed
  Containerization dependency;
- focused authority/runtime/provider integration: 5 tests in 3 suites passed;
- focused attach/hijack/provider integration: 5 tests in 2 suites passed;
- focused Engine logs, hijack, WebSocket, and resize integration: 38 tests
  passed;
- complete clean-built Container validation: 1,832 tests in 213 suites passed;
- Homebrew checksum, init-image installation, and Developer ID archive gates
  passed;
- formatting, licence, and whitespace gates passed;
- signed implementation commit:
  `2d7512c54cfe2fc01d506e08c0300d6f432fd437`;
- signed attach/hijack implementation commit:
  `72a76ab596e95fa775593bc3bcbef67135c384e4`;
- signed complete-response implementation commit:
  `9e23d41fc18dde5ae926e0cbdd1f35d8c86fc512`;
- signed WebSocket attach and terminal-resize implementation commit:
  `6a668b2b5d42246efcad3316374f6d0e0d2eaf14`;
- Engine API 0.3.4 dependency resolves to signed commit
  `73cef37b3693e3fc1acd650782ee7b449ab65b92`;
- the enhanced provider-session integration returns the authority identity,
  container/image counts, complete inspect state/config/host configuration,
  resolved logging options, public json-file path, logs, attach frames, and
  attach/detach events in one passing test.

## Review checklist

- [x] Engine reads the native authority rather than a parallel log source.
- [x] Protected options require authenticated container ownership.
- [x] Active records retain attributes and exact nanoseconds.
- [x] Existing native compatibility streaming is unchanged.
- [x] Wire decoding re-enters bounded core-record validation.
- [x] Provider identity is stable across APIServer restart.
- [x] Only complete generated Engine operations are advertised.
- [x] Attach replay/live, stdin/TTY, detach-key, bounded transport, and
  lifecycle-event semantics use one authority path.
- [x] WebSocket attach reuses the canonical session and resize maps to the
  exact init process with Docker-compatible failures.
- [x] Compose whole `/info` and inspect responses before advertising them.
- [ ] Complete public gateway installation and external-client certification.
