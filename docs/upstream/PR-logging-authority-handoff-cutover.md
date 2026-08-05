# Pull request handoff: complete logging authority cutover through the gateway

> This handoff remains local on `upstream/logging-driver-parity` until the
> complete parity programme is ready for coordinated Apple publication. No
> Apple issue, pull request, branch publication, or push has been created.

## Summary

Drive the production logging source and destination controllers through the
real `ProviderHandoffGatewayCoordinator` instead of calling the controller
operations directly. The focused transaction proves:

- destination possession of the exact archived payload and lineage keys;
- exact-replay source export and source manifest signing;
- closed-inventory manifest assembly with explicit empty evidence for the
  unrelated controller parts;
- immutable object streaming between distinct source and destination stores;
- canonical, ordered 8 MiB transport stores for Docker JSON history above the
  former 64 MiB aggregate ceiling;
- destination stage and exact imported receipt binding;
- prepared-root recording, signed commit, and reconciliation entry;
- logging promotion and signed-Complete activation;
- imported `json-file` history rematerialization through the production bundle
  publisher, including multiple transport stores joined into one active
  `json.log`, public read-back, cursor adoption, and a greater-sequence writer;
- coordinator-driven staged abort, logging compensation, and protected-object
  cleanup; and
- exact replay through a newly constructed coordinator over the same durable
  gateway store plus provider-effect idempotency.

The non-logging controller slots use deterministic empty test responders. The
logging slot uses `LoggingHandoffSourceControlResponder`,
`LoggingHandoffControlResponder`, `LoggingHandoffStagingController`, and
`LoggingHandoffDestinationReconciler` without substitutes.

## Dependency handoff

The test compiles against the matched signed local `container-engine-api`
implementation because released 0.3.5 predates the handoff coordinator API.
`ContainerAPIServiceTests` now declares the `ContainerEngineService` product
explicitly. The manifest's identity-preserving local-package lane selects the
matched Engine API and Containerization worktrees without SwiftPM editable
state; no-override resolution retains the published lockfile exactly.

The Engine API, devcontainer source, and Container destination changes must be
published as one synchronized dependency wave after all programme development
is complete. The released 0.3.5 pin remains unchanged in this handoff.

## Validation

Run only the focused slice while the matched Engine API is editable:

```console
swift test --filter 'gateway coordinator transfers'
swift test --filter 'gateway coordinator aborts'
swift test --skip-build --filter LoggingHandoffControlResponderTests
swift test --skip-build --filter LoggingHandoffPayloadTests
swift test --skip-build --filter LoggingHandoffBundleHistoryPublisherTests
swift format lint --strict --configuration .swift-format-nolint \
  $(git diff --name-only -- '*.swift')
git diff --check
```

Current MacBook Pro evidence:

- gateway cutover: 1/1 passed;
- gateway abort/restart replay: 1/1 passed;
- complete responder slice: 7/7 passed in parallel;
- decoded-payload slice: 6/6 passed, including a shared Engine API payload
  whose encoded JSON history exceeds 64 MiB;
- bundle-history publisher slice: 5/5 passed, including strict incomplete-set
  rejection and repeatable ordered publication into one active file;
- Engine API signed commit `da59cff5b11ba4049f631c886ac3b09b0c3108d6`
  removes the former 4096-store ceiling, and Container signed commit
  `16a3419ae31bb5c18a934571c69348767a89233e` accepts and publishes the
  complete ordered set. Their regressions construct 4097 stores and pass;
- the gateway streamed objects from a distinct source store, recorded two
  destination-key proofs, obtained one source signature, staged and promoted
  logging once, and replayed activation without duplicating the promoted or
  activated effect;
- Complete rematerialized two ordered portable Docker JSON chunks on the public
  bundle path as one active file, the production reader returned both records,
  the adopted cursor reserved epoch 8 from sequence 42, and a production writer
  appended a later readable record;
- a staged remote-provider transaction reached signed Aborted, compensated
  logging twice with equal terminal results across coordinator reconstruction,
  and left zero protected staging objects; and
- the installed readable-plugin fixture completed native lifecycle and
  independent Docker info/inspect/logs certification, then the same deleted
  container ID completed another lifecycle after daemon restart without
  colliding with its prior protected-effect tombstone; and
- SwiftPM editable state was removed after validation.

## Remaining closure

This closes the former 64 MiB source-history gap, coordinator-driven success,
public-history/new-writer, staged-abort/restart-replay, and aggregate portable
store-count transactions. Public Docker create/start routing is closed by
signed Container commit `ac77f7a38819c4f96581220bb58d89107b51826a`, and
provider-root-scoped trust is closed by signed Engine API commit
`fe4094d0d7a2372ad586d177aea3f9b0e299ebcb`. The work package still requires
the synchronized release, external-client, security, failure, migration, and
performance gates before programme-level parity can be claimed.

Installed-system certification and the recreated-container regression are
retained in signed local Container commit
`36ef9c8fbed136641550eed695039440e578de70`.
