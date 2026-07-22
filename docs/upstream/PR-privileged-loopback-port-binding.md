# Pull request handoff: bind privileged loopback host ports on macOS

> [!IMPORTANT]
> The implementation commit is signed and must remain signed and verified when
> offered upstream.

## Summary

Allow a non-root macOS user to publish a host port below 1024 to an explicit
IPv4 or IPv6 loopback address. The listener uses the wildcard address required
by macOS for an unprivileged low-port bind and is restricted to the interface
that owns the requested loopback address.

Fixes [apple/container#1985](https://github.com/apple/container/issues/1985).

## Apple-shaped boundary

- The fix is a generic macOS socket-forwarding primitive with no Compose
  types, configuration, or policy in the Container fork.
- `IP_BOUND_IF` and `IPV6_BOUND_IF` provide the narrow native abstraction
  needed to scope wildcard TCP and UDP listeners.
- Resolution occurs once in `RuntimeService`; the existing forwarders only
  receive an optional interface constraint.
- High ports, wildcard host addresses, and non-loopback host addresses retain
  their existing direct-bind path.

## Code map

- `Sources/Services/RuntimeLinux/Server/HostPortBinding.swift` resolves explicit
  low loopback requests to a wildcard socket restricted to the owning
  interface.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` applies the
  resolved address and interface to TCP or UDP publication.
- `Sources/SocketForwarder/SocketBoundInterface.swift` wraps native IPv4 and
  IPv6 bound-interface socket options.
- `Sources/SocketForwarder/TCPForwarder.swift` and `UDPForwarder.swift` accept
  the optional constraint without changing existing callers.
- `Tests/ServicesTests/RuntimeLinuxTests/HostPortBindingTests.swift` covers
  low/high, loopback/wildcard/non-loopback, IPv4/IPv6, and unassigned-address
  resolution.
- `Tests/SocketForwarderTests/*ForwarderTest.swift` exercises real TCP and UDP
  listeners scoped to the macOS loopback interface.
- `Tests/IntegrationTests/Run/TestCLIRunCommand.swift` starts a source-built
  container with `127.0.0.1:80:80` as a non-root user.

## Validation

```console
make check
swift test --filter HostPortBindingTests
swift test --filter SocketForwarderTest
make test
make integration
```

- `make check` passed formatting and license checks.
- `HostPortBindingTests` passed 7 tests.
- The TCP and UDP forwarder suites passed 4 tests, including real
  interface-scoped listeners.
- `make coverage-unit` passed 1,131 instrumented unit tests in 131 suites and
  regenerated the unit report at 38.69% line coverage.
- The source-build integration gate passed 3 warmup tests, 238 concurrent tests
  in 27 suites, and 143 serial tests in 14 suites.
- The live integration case successfully published `127.0.0.1:80:80` as the
  non-root MacBook Pro user, then inspected, stopped, and removed the container.

Docker Compose V2 behavior is exercised by the downstream Compose pin and
strict parity gate before the prerelease is published.

## Compatibility and risks

The alternate bind path is limited to explicit IPv4 or IPv6 loopback
addresses with host ports below 1024. Binding the wildcard socket to the
owning interface prevents connections through other host interfaces; a local
probe confirmed that the loopback-scoped listener accepts `127.0.0.1` and
does not accept a different loopback destination. If the requested loopback
address is not assigned to a host interface, the request fails before the
listener is created.

## PR template

### Type of change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

### Motivation and context

macOS permits an unprivileged low-port bind on a wildcard socket but rejects
the equivalent direct loopback bind. Restricting that wildcard socket to the
loopback interface restores the requested local-only behavior without
requiring root or widening host exposure.

### Testing

- [x] Tested locally on macOS
- [x] Added and updated unit tests
- [x] Added macOS integration coverage
- [x] Updated documentation
- [ ] Docker Compose V2 parity (completed in the downstream Compose pin)

## Commit tracking

- `71cdae6b695508086cef81b94e9ad77a633635f6`
  (`fix(network): bind privileged loopback ports`)
