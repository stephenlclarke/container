# Pull request: scope attachment-name validation to each network

> [!IMPORTANT]
> All commits in this handoff are signed and verified.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Container creation previously used one global hostname/alias registry for every
network attachment. That rejected a valid configuration where two different
networks each used the same attachment alias or hostname. The validation
belongs to the generic network-attachment boundary and must be scoped by
network identifier.

This change fixes that validation only. It is a prerequisite for future
network discovery work, not an assertion that aliases currently resolve inside
guests.

## Apple-shaped boundary

- `apple/containerization`: No change; the runtime already represents network
  attachments independently.
- `apple/container`: Scope generic attachment-name collision validation to each
  `AttachmentConfiguration.network`.
- `container-compose`: No change; it must continue to reject unsupported
  service aliases until guest discovery is implemented end to end.

No Compose vocabulary, Docker behavior, or Compose-specific abstraction is
introduced in product code.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  gathers names by network and preserves the existing collision error before
  any runtime side effects.
- `Tests/ContainerAPIServiceTests/ContainerNetworkNameValidationTests.swift`
  covers cross-network reuse, same-network conflicts, and duplicate requested
  names in one network.
- `Tests/IntegrationTests/Network/TestCLINetwork.swift` creates two named
  networks and verifies two stopped containers can each reserve `api`, then
  cleans all test resources in dependency order.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Completed locally on macOS 26.5.2 with Xcode 26.6:

```sh
swift format lint --strict --configuration .swift-format-nolint \
  Sources/Services/ContainerAPIService/Server/Containers/\
ContainersService.swift \
  Tests/ContainerAPIServiceTests/ContainerNetworkNameValidationTests.swift \
  Tests/IntegrationTests/Network/TestCLINetwork.swift
swift test --skip-build \
  --filter ContainerNetworkNameValidationTests
make coverage-unit \
  SWIFT_TEST_FLAGS='--filter ContainerNetworkNameValidationTests'
CLITEST_SCRATCH_ROOT="$PWD/.test-scratch" \
  CONTAINER_CLI_PATH="$PWD/bin/container" \
  swift test --skip-build -c debug -Xswiftc -warnings-as-errors \
  -Xswiftc -enable-testing --filter 'TestCLINetwork.testNetworkScopedAttachmentNames'
git diff --check
```

The focused unit suite passed all three tests. The coverage-instrumented run
executed every executable line in `conflictingNetworkNames`; the repository-wide
percentage is intentionally not meaningful for a focused three-test run. The
macOS integration test passed and confirmed both container creations and all
resource cleanup operations succeed.

## Docker Compose V2 parity status

No Docker Compose YAML integration test is claimed for this isolated generic
runtime correction. Docker Compose V2 network aliases require both allocation
and guest-visible name resolution. The current runtime lacks the latter, so a
Compose adapter or a `DockerCompose.yml` parity fixture would overstate
capability. The linked issue document records the required follow-up boundary.

## Compatibility and risks

- Same-network hostname and alias conflicts remain rejected with sorted
  conflicting names.
- Distinct networks can now reuse an attachment name, matching the isolation
  implied by the generic network model.
- No persisted schema, CLI flag, public API, or Windows behavior changes.
- Guest DNS and service discovery remain unimplemented and must not be inferred
  from this change.

## Review checklist

- [ ] Confirm `17cc06a514bd15ec1236e01f0ad7a9bce02aaa6b` remains based on the
  current Apple upstream before opening the PR.
- [ ] Confirm the commit signature is verified.
- [ ] Confirm same-network collisions still fail before runtime side effects.
- [ ] Confirm no Compose alias adapter is added until guest DNS resolution has
  end-to-end coverage against Docker Compose V2.

## Commit tracking

- `container` code and tests:
  `17cc06a514bd15ec1236e01f0ad7a9bce02aaa6b`
  (`fix(network): scope attachment names per network`).
- `containerization` code change: none.
