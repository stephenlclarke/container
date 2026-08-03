# Pull request: add a Docker-compatible Splunk HEC logging provider

> [!IMPORTANT]
> This handoff remains local until the complete parity programme is ready for
> coordinated Apple publication. All eventual handoff commits must be signed
> and verified.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The API authority already owns provider selection, protected logging options,
runtime pipes, delivery buffering, and crash-safe lifecycle fencing. Adding the
Splunk driver at that boundary closes the HEC transport gap without exposing
credentials to the runtime or adding Docker-specific types to lower layers.

The wire and option semantics are pinned to the Moby 29.2.1 Splunk driver. The
implementation deliberately uses the existing generic logging-provider
contracts so a Compose adapter or another client can select it through the
same structured log request.

## Implementation

- Add a complete Splunk option resolver, including URL validation, protected
  token handling, Docker template and RE2 metadata semantics, event format,
  gzip, verification, index acknowledgement, proxy, and TLS controls.
- Encode Moby-compatible concatenated HEC event objects with stable field
  ordering, fractional Unix timestamps, raw/json/inline behavior, and optional
  gzip levels from `-1` through `9`.
- Add a production `URLSession` transport with bounded response reads, request
  deadlines, task- and session-level TLS challenges, custom trust anchors,
  server-name override, insecure verification, and proxy environment support.
- Add a bounded session with 1,000-event/five-second batching, retry retention,
  oldest-batch overflow eviction, final-close behavior, and serialized flush,
  fence, and close operations.
- Add the provider's protected effect token, idempotent start, reconciliation,
  generation fencing, and close lifecycle; register it in the built-in remote
  provider catalog and API-authority configuration plane.
- Keep `splunk-token` out of safe options, persistence, reflection, descriptions,
  and response diagnostics.

## Code map

- `Sources/ContainerLoggingProviders/Splunk/` contains the contract, resolver,
  encoder, transport, session, and lifecycle provider.
- `Sources/ContainerLoggingProviders/BuiltinRemoteLogDriverProviderSet.swift`
  installs the provider and holds its exact typed configuration binding.
- `Sources/Services/ContainerAPIService/Server/Containers/AuthorityRemoteLogDriverPlane.swift`
  resolves authenticated options at the authority boundary.
- `Tests/ContainerLoggingProvidersTests/Splunk*Tests.swift` covers configuration,
  wire encoding, batching, retry/drop behavior, lifecycle fencing, and real
  HTTP/TLS loopback transport.
- `Tests/ContainerAPIServiceTests/ContainerLoggingAuthorityIntegrationTests.swift`
  proves create/start contract pinning and protected-token persistence safety.

## Testing

- [x] Tested locally on the programme MacBook Pro
- [x] Added/updated tests
- [x] Added/updated docs

Focused evidence completed:

```sh
swift test --disable-automatic-resolution --filter Splunk
swift test --disable-automatic-resolution \
  --filter ContainerLoggingAuthorityIntegrationTests.splunkCreateSealsTokenAndPinsProviderContract
make check
```

The Splunk suites pass 17 tests, the authority integration adds one protected
token test, production HTTP and custom-CA TLS requests are exercised against a
real local NIO server, and formatting plus license checks pass. Record the
single final full-repository gate and exact signed commit below before Apple
publication. The final `make test` gate also passes all 1,751 Swift tests in 199
suites, the pinned Go semantic-helper test, the Homebrew archive checksum, and
the init-image/install validation stages.

## Compatibility and risks

- The provider is additive; existing core and remote drivers are unchanged.
- URL and option validation intentionally fail closed at container start, the
  same phase in which the protected token becomes available.
- Remote response bodies are capped at 1,024 bytes and never enter diagnostics.
- The implementation follows Moby's bounded retry and last-chance discard
  behavior, so a persistently unavailable collector can still lose the oldest
  buffered batch. That is a compatibility property, not durable log storage.
- Native `docker logs` reads remain unavailable unless the existing dual-cache
  policy is selected.

## Validation and commit tracking

- Final full repository gate: `make test`, passed locally on 2026-08-03.
- Signed local implementation commit: pending.
- Branch: `upstream/logging-driver-parity`.
- Apple publication: intentionally deferred until all programme development is
  complete.

Related issue handoff: `docs/upstream/ISSUE-splunk-log-driver.md`.
