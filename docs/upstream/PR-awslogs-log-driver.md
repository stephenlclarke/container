# Pull request: add a Docker-compatible AWS Logs provider

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

The API authority already owns logging-provider selection, protected effects,
runtime pipes, delivery buffering, and crash-safe lifecycle fencing. Adding
AWS Logs there closes the CloudWatch transport gap without placing credentials
in persisted logging options or introducing AWS types into the core provider
contract.

The option, creation, queue, multiline, batch, and sequence-token semantics are
pinned to Moby 29.2.1 commit
`6bc6209b88a7a834c91f77d848e025c79e0227a1`.

## Implementation

- Add the complete AWS Logs option resolver, Docker template and RE2 multiline
  behavior, presence-sensitive conflicts, region precedence, and exact
  CloudWatch size/queue defaults.
- Add a dependency-neutral client protocol and a separately isolated official
  AWS Swift SDK adapter. The adapter uses the default credential chain, IMDS
  region discovery, optional ECS-style endpoint credentials, SigV4, service
  endpoint resolution, SDK retry behavior, Docker user agent, and `json/emf`
  header.
- Add blocking and non-blocking stream creation, bounded 4,096-event startup
  queue, Moby-compatible exponential creation retry, stable batching, UTF-8
  event splitting, sequence-token recovery, terminal drop behavior, and timed
  flush.
- Add protected effect-token, idempotent start, reconciliation, generation
  fencing, and close lifecycle behavior; register the provider in the built-in
  catalog and API-authority configuration plane.

## Code map

- `Sources/ContainerLoggingProviders/AWSLogs/` contains the contract, resolver,
  dependency-neutral client boundary, session, and lifecycle provider.
- `Sources/ContainerAWSLogsSDKAdapter/` contains the production AWS SDK bridge.
- `Sources/ContainerLoggingProviders/BuiltinRemoteLogDriverProviderSet.swift`
  installs the provider and stores its exact typed configuration binding.
- `Sources/Services/ContainerAPIService/Server/Containers/AuthorityRemoteLogDriverPlane.swift`
  resolves and activates the provider at the authority boundary.
- `Tests/ContainerLoggingProvidersTests/AWSLogs*Tests.swift` covers option,
  creation, multiline, batching, splitting, sequencing, and lifecycle behavior.
- `Tests/ContainerAPIServiceTests/AuthorityRemoteLogDriverPlaneTests.swift`
  proves production-plane publication through the registered provider.

## Testing

- [x] Tested locally on the programme MacBook Pro
- [x] Added/updated tests
- [x] Added/updated docs

Focused evidence:

```sh
swift test --filter AWSLogs
swift test --filter \
  AuthorityRemoteLogDriverPlaneTests/awsLogsProductionPlanePublishesProviderBytes
make check
```

Record the one final full-repository gate and signed implementation commit in
the validation section before Apple publication.

## Compatibility and risks

- The provider is additive; existing native and remote drivers are unchanged.
- The official SDK is isolated behind a small protocol so its native modules do
  not leak into the provider module or downstream test targets.
- Credential bytes come from AWS's default authority-owned chain or the
  explicit endpoint and never enter resolved logging options or diagnostics.
- Like Moby, persistent CloudWatch publication failures are logged and the
  failed batch is dropped; this provider is not durable log storage.
- Native `docker logs` reads remain unavailable unless dual cache is selected.

## Validation and commit tracking

- Final full repository gate: pending.
- Signed local implementation commit: pending.
- Branch: `upstream/logging-driver-parity`.
- Apple publication: intentionally deferred until all programme development is
  complete.

Related issue handoff: `docs/upstream/ISSUE-awslogs-log-driver.md`.
