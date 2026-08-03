# Pull request handoff: compose the shared Linux sandbox API authority

## Summary

- Add one actor-isolated API-service composition root for launchd supervision,
  durable sandbox/workload state, exact runtime reconciliation, and workload
  start transactions.
- Make a durable ready record conditional on observing the exact live runtime
  identity after API-service restart.
- Bind sealed workload materialization to a canonical runtime-configuration
  digest and reject conflicting replays.

## Type of change

- [x] Generic runtime API
- [x] API-service composition and helper supervision
- [x] Crash-recovery and lifecycle behavior
- [x] Bundle-integrity validation
- [x] Unit tests
- [ ] Docker or Compose parsing
- [ ] Engine REST or socket API
- [ ] `ContainersService` traffic cutover

## Authority contract

`EngineLinuxSandboxAuthorityV1` is the only composition point for the shared
helper. It opens the workload ledger, owns a common runtime client satisfying
both sandbox and workload protocols, constructs the sandbox manager and plan
resolver, and serializes launch/start/shutdown decisions. The production
launcher accepts only `container-runtime-linux`, writes its bounded private
configuration, and registers the stable helper instance with the
`shared-sandbox` command.

The authority derives deterministic boot, stop, and workload request
identities. Workload request material includes the plan digest, configuration
digest, dynamic environment, and resolved endpoint plan. An exact running
request replays; a changed request conflicts before another process operation.

## Restart and integrity fixes

`EngineLinuxSandboxManagerV1` now observes every ready replay and compares the
full sandbox ID, generation, effect ID, request digest, and runtime
fingerprint. Missing, mismatched, or inconclusive runtime state becomes a
durable recovery-required record. The ready ledger schema now also requires
the idempotency key needed to reconstruct that exact observation request.

Workload requests carry a SHA-256 digest of the decoded, deterministically
encoded `RuntimeConfiguration`. The API authority and helper each hash the
same value they subsequently use; the helper rejects a mismatch before adding
or starting a workload. This closes both post-reservation mutation and
double-read time-of-check/time-of-use gaps.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/EngineLinuxSandboxAuthority.swift`
  contains the production launcher and API-service authority.
- `Sources/ContainerResource/Container/EngineLinuxSandboxManager.swift` and
  `EngineWorkloadLedger.swift` enforce ready-state reconciliation evidence.
- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxRuntimeClient.swift`
  exposes the common sandbox/workload client contract.
- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxWorkloadRuntime.swift`
  carries and derives workload-configuration integrity evidence.
- `Sources/Services/RuntimeLinux/Server/EngineLinuxSandboxRuntimeService.swift`
  validates that evidence before materialization.
- Focused tests cover restart reuse, exact replay, conflicting replay,
  disappeared VM identity, and bundle mutation.

## Dependency handoff

The authority uses the local Containerization shared-workload and observation
APIs on `upstream/engine-linux-sandbox`. Container's published dependency pin
and `Package.resolved` remain unchanged. Local SwiftPM edit metadata was
removed after validation.

No Apple issue, branch, pull request, or push has been created. The signed
local commit is retained for the coordinated programme-wide upstream wave.

## Validation

```console
swift build --target ContainerAPIService
swift test --filter EngineLinuxSandboxAuthorityTests
swift test --filter 'Engine(WorkloadLedger|LinuxSandboxRuntimeService|LinuxSandboxAuthority)Tests'
make check
git diff --check
```

Results on the development MacBook Pro:

- API-service target builds with the local signed Containerization dependency;
- authority integration: 1 test in 1 suite passed;
- combined authority/manager/runtime evidence: 15 tests in 3 suites passed;
- runtime integrity suite after the final single-read change: 6 tests passed;
- formatting, licence, and whitespace gates passed;
- implementation commit
  `203c88b4d71d25a3ef6036035c54ca8b65f4923c` is signed.

## Deliberate boundaries and review checklist

- [x] No durable ready record is trusted without live exact observation.
- [x] Launch and start composition is actor-isolated and replay-safe.
- [x] Workload materialization is bound to the configuration actually used.
- [x] Existing running success cannot satisfy changed workload intent.
- [x] The authority accepts specialized controllers without owning their
  policy.
- [x] No Docker-specific behavior enters this generic layer.
- [ ] Add scoped exec/attach/wait/stats/copy/stop/remove helper routes.
- [ ] Implement production effect controllers and guest network/IPAM broker.
- [ ] Cut `ContainersService` lifecycle traffic over under feature gating,
  migration, rollback, and performance evidence.

The first specialized Engine adapter follow-up is signed at
`2d7512c54cfe2fc01d506e08c0300d6f432fd437`: Docker log reads now use the
existing Container authority and a lossless active-generation wire. Shared
sandbox lifecycle cutover remains outstanding.
