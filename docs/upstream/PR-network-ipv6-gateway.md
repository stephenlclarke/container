# Pull request: configure an IPv6 gateway for custom vmnet networks

> [!IMPORTANT]
> All commits in this handoff are signed and verified.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`NetworkConfiguration` previously represented an IPv6 subnet but not its
gateway. The vmnet implementation therefore selected `prefix + 1` even when a
higher-level macOS client had an explicit IPv6 IPAM gateway to preserve. The
custom vmnet `NATNetworkInterface` also had no IPv6 fields, leaving the guest
without the selected IPv6 default route.

## Apple-shaped boundary

- `apple/containerization`: `fe272b22c133bd82e319d3c91863fe11abe708a0` adds
  optional generic IPv6 address and gateway values to `NATNetworkInterface`.
- `apple/container`: this change adds an optional generic IPv6 gateway to the
  network configuration, runtime status, attachment, vmnet helper, and guest
  interface strategies.
- `container-compose`: a separate adapter may map Docker Compose IPv6 IPAM
  configuration through this generic API; no Compose type or parser appears in
  this patch.

## Code map

- `Sources/ContainerResource/Network/NetworkConfiguration.swift` validates,
  persists, and serializes the optional IPv6 gateway.
- `Sources/Services/NetworkVmnet/Server/ReservedVmnetNetwork.swift` passes the
  selected gateway to vmnet's existing IPv6 prefix configuration and exposes
  the resolved value in runtime status.
- `Sources/Services/Network/Server/DefaultNetworkService.swift` carries the
  status gateway into attachments and rejects a requested guest address that
  equals it.
- `Sources/Services/RuntimeLinux/Server/` passes IPv6 addresses and the
  primary-interface IPv6 gateway to the existing guest route configuration.
- `Sources/ContainerCommands/Network/NetworkCreate.swift` and the plugin helper
  expose the generic `--gateway-v6` command option.
- `Tests/ContainerResourceTests/NetworkConfigurationTest.swift` covers Codable
  compatibility and invalid configuration. `Tests/IntegrationTests/Network/
  TestCLINetwork.swift` creates a network with an explicit gateway and verifies
  the guest default route.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

```sh
swift test --disable-automatic-resolution --filter NetworkConfigurationTest \
  --no-parallel
CONTAINER_CLI_PATH="$PWD/bin/container" swift test --filter \
  'TestCLINetwork/testNetworkCreateWithIPv6Gateway' --no-parallel
```

The focused unit suite passed 50 tests, covering IPv6 gateway round trips,
legacy status decoding, invalid inputs, and guest-interface propagation. The
macOS integration test creates a custom network with `fd42:4242:4242::53` as
gateway and checks the guest's IPv6 default route uses that address.

## Docker Compose V2 parity status

This generic runtime patch does not parse Compose YAML. A separate Compose
slice performs the Docker Compose V2 configuration and runtime parity check;
this patch supplies only the Apple-shaped primitive it requires.

## Compatibility and risks

- The gateway is optional; omitted configuration continues to use `prefix + 1`.
- Existing persisted configuration and status records decode without a gateway.
- The change is limited to macOS vmnet-hosted Linux guests. No Windows or
  Linux-host behavior is changed.

## Review checklist

- [ ] Confirm the Containerization dependency commit remains based on the
  current Apple upstream before opening the Apple PR.
- [ ] Confirm both fork commits are signed and verified.
- [ ] Confirm invalid gateways fail before vmnet helper startup.
- [ ] Confirm a guest receives the requested IPv6 default route.

## Commit tracking

- `containerization` code: `fe272b22c133bd82e319d3c91863fe11abe708a0`
  (`feat(network): carry IPv6 on custom vmnet interfaces`).
- `container` code and tests: `c194d29` (`feat(network): add IPv6 gateway
  control`).

Related issue handoff: `docs/upstream/ISSUE-network-ipv6-gateway.md`.
