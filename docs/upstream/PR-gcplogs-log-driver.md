# Pull request: add a Docker-compatible Google Cloud Logs provider

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
Google Cloud Logs there closes the Google transport gap without placing
credentials in persisted logging options or introducing Google SDK types into
the Swift provider contract.

The option, metadata, payload, delivery, overflow, and close semantics are
pinned to Moby 29.2.1 commit
`6bc6209b88a7a834c91f77d848e025c79e0227a1`. The exact pinned
`gcplogging.go` source digest is
`07e3f6d88058802bb5c28fe40905c0ff8e458c4df47e0d6303eeedb26c23b659`.

## Implementation

- Add the complete Google Cloud Logs option surface, project precedence,
  compute and explicit instance metadata, command inclusion, and Docker label
  and environment selection behavior.
- Extend the signed Go semantic helper with Moby's pinned behavior and the
  exact official Google dependencies selected by Moby. Its manifest, source
  digest, handshake, and reproducible build cover the new implementation and
  `go.sum` dependency graph.
- Launch only the GCP helper pool with the authority environment needed for
  complete Application Default Credentials behavior. Dynamic-loader injection
  variables are removed before spawn; other helper users retain the restricted
  default environment.
- Add official-client `Ping`, `gce_instance` resource configuration,
  asynchronous `Log`, overflow reporting, `Flush`, and `Close` lifecycle
  operations over the bounded helper protocol.
- Add protected effect-token, idempotent start, reconciliation, generation
  fencing, and close lifecycle behavior; register the provider in the built-in
  catalog and API-authority configuration plane.

## Code map

- `Sources/ContainerLoggingProviders/GCPLogs/` contains the contract,
  configuration, helper-backed session, and lifecycle provider.
- `Sources/DockerSemanticHelper/` contains the versioned GCP lifecycle client,
  verified provenance manifest, and generation-scoped helper pool.
- `Sources/CSemanticHelperProcess/` contains the opt-in, loader-safe authority
  environment inheritance used for Application Default Credentials.
- `Tools/ContainerSemanticHelper/` contains the pinned Moby semantics,
  official Google Cloud Logging adapter, protocol server, reproducible builder,
  and Go tests.
- `Sources/ContainerLoggingProviders/BuiltinRemoteLogDriverProviderSet.swift`
  installs the provider and stores its exact typed configuration binding.
- `Sources/Services/ContainerAPIService/Server/Containers/AuthorityRemoteLogDriverPlane.swift`
  resolves and activates the provider at the authority boundary.
- `Tests/ContainerLoggingProvidersTests/GCPLogsProviderTests.swift` and the
  helper tests cover options, payloads, metadata, lifecycle, and failure
  behavior.
- `Tests/ContainerAPIServiceTests/AuthorityRemoteLogDriverPlaneTests.swift`
  proves production-plane publication through the registered provider.

## Testing

- [x] Tested locally on the programme MacBook Pro
- [x] Added/updated tests
- [x] Added/updated docs

Focused evidence:

```sh
make test-semantic-helper
swift test --filter DockerSemanticHelperClientTests
swift test --filter gcpLogsProductionPlanePublishesProviderBytes
make check
```

The semantic-helper suite passes at 81.6% statement coverage. The full
repository gate also passes all 1,768 Swift tests in 203 suites, the pinned Go
semantic-helper suite, Homebrew archive checksum verification, and the
init-image/install validation stages.

## Compatibility and risks

- The provider is additive; existing native and remote drivers are unchanged.
- Official Google SDK types and credential handling remain inside the signed
  helper and do not leak into the provider module or runtime transport.
- Credential material is resolved only in the API-authority process boundary
  and never enters logging options, persisted lifecycle records, or
  diagnostics.
- Like Moby, publication is asynchronous and the official client can drop
  entries when its bounded queue overflows; the provider surfaces the first
  and every thousandth overflow.
- Native `docker logs` reads remain unavailable unless dual cache is selected.

## Validation and commit tracking

- Final full repository gate: `make test`, passed locally on 2026-08-03.
- Signed local implementation commit:
  `2a79b4553a342e33411666a88ad20ccd2ce46551`
  (`feat(logging): implement Google Cloud Logs provider`).
- Branch: `upstream/logging-driver-parity`.
- Apple publication: intentionally deferred until all programme development is
  complete.

Related issue handoff: `docs/upstream/ISSUE-gcplogs-log-driver.md`.
