<!-- markdownlint-disable MD013 -->

# Pull request handoff: route Docker's GELF host alias from the native provider

## Summary

- Preserve Docker-visible `gelf-address` values containing `host.docker.internal`.
- Translate the Docker VM alias to `127.0.0.1` only when the native macOS GELF transport opens a TCP or UDP connection.
- Cover the canonical TCP spelling and a case-variant UDP spelling with live loopback receivers.
- Retain the Docker reconnect oracle and public-socket candidate certificate as the completion authority.

## Scope

This is a narrow Container-native GELF transport compatibility change. It deliberately excludes Docker Engine endpoint parsing, Compose configuration projection, guest hostname setup, generic DNS aliases, logging-driver retry policy, and upstream publication.

## Implementation

`NIOGELFTransportFactory` now derives its connection host through one private helper. Empty hosts still become `localhost`. On macOS only, an ASCII case-insensitive `host.docker.internal` matches Docker's VM host alias and becomes `127.0.0.1`; every other configured hostname remains unchanged. The helper is used by both `ClientBootstrap` and `DatagramBootstrap`, so TCP and UDP share the same placement correction without rewriting `GELFConfiguration` or inspect output.

`GELFTransportLoopbackTests` starts independent UDP and TCP receivers on local IPv4 loopback, configures the provider with Docker's alias, and verifies the normal uncompressed GELF payload and NUL-framed TCP payload. The UDP case deliberately uses an uppercase hostname to keep DNS case-insensitivity covered.

## Docker oracle and validation

Pinned reference: Docker Engine 29.2.1 with Docker CLI 29.7.1 on the programme MBP. The bounded reconnect oracle accepts `tcp://host.docker.internal:PORT`, closes the first GELF connection after its first frame, and observes recovery on a second connection.

- `swift format --configuration .swift-format -i Sources/ContainerLoggingProviders/GELF/NIOGELFTransport.swift Tests/ContainerLoggingProvidersTests/GELFTransportLoopbackTests.swift` completed without additional changes.
- `git diff --check` passes.
- `swift test --skip-build --filter productionDockerHostAliasRoutesTCPAndUDPToNativeLoopback` passes with the matched local Containerization `38d9c69` and Engine API `4949e743` overrides; the source build that created the test bundle also passed the filter.
- The marker-protected focused-test evidence is `/private/tmp/container-gelf-native-alias-unit-matched.D850uv/swift-test.log`.
- Fresh final-commit packaging and two isolated public Docker CLI reconnect runs remain required before this contract is Verified.

## Review checklist

- [x] The persisted/API-visible endpoint is not rewritten.
- [x] TCP and UDP transport paths use the same narrowly scoped mapping.
- [x] Empty and non-alias hosts retain their existing behavior.
- [x] A live focused regression covers the native loopback connection and record framing.
- [ ] A fresh signed candidate archive passes the public Docker CLI reconnect contract twice.
- [ ] Timing comparison, broader checkpoint gates, and programme-ledger updates run at the coherent checkpoint.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all programme development is complete and the user explicitly authorises the coordinated Apple upstream wave.

Related issue handoff: `docs/upstream/ISSUE-gelf-native-host-alias.md`.

<!-- markdownlint-enable MD013 -->
