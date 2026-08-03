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
- Start one restart-stable enhanced provider session and advertise only the
  complete `ContainerAttach` and `ContainerLogs` generated Engine operations.

## Type of change

- [x] Generic Container runtime transport
- [x] API-service authority adapter
- [x] Engine private provider session
- [x] Docker logging REST/streaming projection
- [x] Protected-option authentication
- [x] Unit and provider-session integration tests
- [ ] Public Engine listener installation
- [ ] Complete `/info` or inspect route composition
- [x] Attach/hijack route advertisement
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

## Provider identity and route gating

`container-apiserver` loads or creates one provider-owned state-root UUID,
builds an enhanced `container-authority` declaration from Container and
Containerization revisions plus exact Engine API release 0.2.2, and starts a
private singleton provider socket. Cancellation shuts the provider down.

The fingerprint advertises `engine.route.ContainerAttach` and
`engine.route.ContainerLogs`. Although the
logging backend implements the logging projections needed by `/info` and
inspect, those generated operations cover whole shared responses and cannot be
advertised until the remaining fields are composed. WebSocket attach and
resize remain separate operations for the common public gateway and are not
claimed by this provider declaration.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainerDockerLoggingBackend.swift`
  contains the neutral backend, direct and active-wire readers, runtime attach
  bridge, detach filter, and bounded hijack session.
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

Container pins `container-engine-api` exactly at 0.2.2. Validation uses the
local signed Containerization shared-sandbox worktree because the coordinated
Containerization upstream wave has not been published. SwiftPM editable state
is removed after validation; the published Containerization pin remains
unchanged.

No Apple issue, pull request, branch publication, or push has been created.
The complete change remains local until all parity development is complete.

## Validation

```console
swift build --target ContainerAPIService
swift build --target container-apiserver
swift test --filter 'ContainerDockerAttachSessionTests|engineLoggingBackendUsesAuthoritativeInspectionAndExactReader'
swift test --filter 'ContainerLogReaderStreamTests|ContainerLogsTests.engine|ContainerLoggingAuthorityIntegrationTests.engineInspect'
make check
git diff --check
```

Current development MacBook Pro evidence:

- Container API service and APIServer targets build against the local signed
  Containerization dependency;
- focused authority/runtime/provider integration: 5 tests in 3 suites passed;
- focused attach/hijack/provider integration: 5 tests in 2 suites passed;
- formatting, licence, and whitespace gates passed;
- signed implementation commit:
  `2d7512c54cfe2fc01d506e08c0300d6f432fd437`;
- signed attach/hijack implementation commit:
  `72a76ab596e95fa775593bc3bcbef67135c384e4`.

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
- [ ] Compose whole `/info` and inspect responses before advertising them.
- [ ] Add WebSocket attach and resize through the common public gateway.
- [ ] Complete public gateway installation and external-client certification.
