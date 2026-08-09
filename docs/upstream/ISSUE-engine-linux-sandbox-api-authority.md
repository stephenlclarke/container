# Runtime gap: API-service authority for the shared Linux sandbox

## Problem

The shared Linux runtime helper, durable workload ledger, and transaction
resolver existed as independently tested components, but the API service had
no production composition root for them. It could not launch or reconnect to
the Engine-owned helper, reopen the durable ledger, reconcile the exact VM,
or route a sealed workload start through one authority.

Two restart and integrity defects also prevented a safe cutover:

- a durable `ready` record was accepted without observing that the exact VM
  generation, request, effect, and runtime fingerprint still existed; and
- the helper reread a bundle path but the request did not bind the start to a
  digest of the runtime configuration, allowing the bundle model to change
  between reservation and materialization.

## Required behavior

- Own the stable helper identifier, private configuration root, launchd
  registration, XPC client, durable ledger, sandbox manager, and workload
  resolver in one actor-isolated API-service authority.
- Reuse an active same-label launchd helper and replace a stopped helper only
  when its persisted launch configuration is incompatible.
- On every ready replay, observe and compare the complete runtime identity;
  fence the durable sandbox as recovery-required if it is absent, mismatched,
  or cannot be observed conclusively.
- Bind the workload transaction digest to the plan, canonical runtime
  configuration digest, dynamic environment, and resolved network endpoints.
- Read and hash one decoded runtime-configuration value at each side of the
  XPC boundary so validation and materialization cannot disagree through a
  second read.
- Reject a changed request for an already-running workload instead of
  returning an unrelated prior success.
- Preserve controller specialization: the common authority orders supplied
  effect controllers but does not absorb network, storage, logging, security,
  device, model-routing, or Engine-socket policy.

## Acceptance evidence

- [x] Production launchd launcher hard-gates the Linux runtime plugin and uses
  the dedicated `shared-sandbox` command.
- [x] File-backed and injected persistence construction are supported.
- [x] Sandbox boot intent and workload-start intent use deterministic exact
  identities.
- [x] A fresh authority reconciles an existing ready VM without another boot.
- [x] Missing runtime identity durably fences a formerly ready sandbox.
- [x] Workload configuration mutation is rejected before materialization.
- [x] Identical workload starts replay without another process start.
- [x] Changed environment or endpoint intent conflicts with prior running
  success.
- [x] Focused authority, manager, and helper tests pass on the development
  MacBook Pro.
- [x] Formatting, licence, and whitespace gates pass.
- [x] Protected service dials validate the exact sandbox ID/generation,
  workload ID/process generation, and service port at both authority and
  helper boundaries.
- [x] Monitored terminal workloads withdraw their retained receipt, are
  durably reclaimed, and can be rematerialized under a later exact process
  generation.
- [x] Authority-requested protected workload stop is exact-generation fenced,
  observable, idempotent, and replay-safe after a lost XPC response.

## Remaining production cutover

This change establishes the authority boundary but deliberately does not route
the existing `ContainersService` lifecycle through it. That cutover first
requires production controllers for the effect domains and shared-sandbox
routes for exec/attach/wait/stats/copy/stop/remove. Advanced network/IPAM must
also provide guest endpoint plans rather than the legacy VM-interface model.
The protected-provider stop route is complete; the remaining stop/remove work
is the general `ContainersService` lifecycle cutover.

Until those pieces are complete, the legacy per-container runtime path remains
the production lifecycle path. The new authority is not presented as full
Docker or Compose parity by itself.

The enhanced Engine logging provider is now composed separately at signed
commit `2d7512c54cfe2fc01d506e08c0300d6f432fd437`. It reads the existing
per-container authority and exact retained logging generation; it does not yet
cut general container lifecycle traffic over to the shared sandbox.

The production journald worker is the first protected workload routed through
the shared-sandbox authority. Signed commit
`84d160671f3ba6c265a02b49b2ff4309f6584d30` adds exact workload-generation
service dials, terminal readiness withdrawal/reclamation, OCI materialization,
and live catalog probing. This closes the protected-service path without
changing the remaining general `ContainersService` lifecycle-cutover scope.

Signed commit `6e462443dd744bda0b605bf26e093833d7818e77` adds exact protected-workload
stop intent, observation, response-loss reconciliation, and durable workload
reclamation before a provider generation is forgotten.

## Apple-shaped boundary

This is generic Container runtime composition. It contains no Docker or
Compose parsing, REST route, compatibility fallback, or provider selection.
It is retained locally for coordinated Apple upstream publication only after
the complete parity programme is finished.

## Commit tracking

- `203c88b4d71d25a3ef6036035c54ca8b65f4923c` — signed implementation and
  focused tests.
- `84d160671f3ba6c265a02b49b2ff4309f6584d30` — signed exact service routing,
  terminal workload recovery, and production journald supervision follow-up.
- `6e462443dd744bda0b605bf26e093833d7818e77` — signed exact workload-stop and
  provider-generation reclamation follow-up.
