# Runtime gap: transactional workload plan resolution

## Problem

The durable workload ledger can record lifecycle intent and exact effect
identity, but callers still need a common executor for specialized namespace,
network, volume, resource, logging, security, device, model, root filesystem,
and engine-socket effects. Without one executor, each caller can order and
recover the same plan differently.

The missing transaction layer creates four risks:

- an effect can run before its durable reservation is recorded;
- a lost response can cause a confirmed effect or process start to run twice;
- failed starts can compensate dependencies in the wrong order;
- an inconclusive observation can be treated as absence instead of fencing the
  workload for recovery.

## Required runtime behavior

- Accept specialized controllers in explicit dependency order and reject
  duplicate effect domains before mutating the ledger.
- Require side-effect-free, deterministic reservations and persist each exact
  lease/effect tuple before apply.
- Validate the complete controller receipt tuple rather than trusting a
  successful return alone.
- Observe a thrown apply or process-start call and distinguish confirmed
  success, confirmed absence, and unknown outcome.
- Continue after a confirmed lost-response success without repeating the
  effect.
- Compensate confirmed effects in reverse dependency order after a known
  failure.
- Fence the workload and preserve exact evidence whenever apply, process start,
  or compensation remains uncertain.
- Replay interrupted starts without reapplying effects already acknowledged by
  the ledger, and make committed request replay a no-op.

## Apple-shaped boundary

This is generic Container lifecycle infrastructure. It contains no Docker or
Compose syntax, provider selection, compatibility fallback, REST route, or
socket protocol. Specialized controllers retain ownership of their external
resources and supply only exact reservations, receipts, observations, and
compensation behavior.

The implementation is retained locally for a later Apple upstream handoff. It
must not be published to an Apple repository until the complete parity
programme is ready for upstream submission.

## Acceptance evidence

- [x] Reservations are persisted before apply.
- [x] Exact receipts are validated for effects and process starts.
- [x] Lost responses reconcile without duplicate apply.
- [x] Known failures compensate in reverse order.
- [x] Unknown apply and process outcomes fence the workload.
- [x] Interrupted starts skip already acknowledged effects.
- [x] Committed retries return without external work.
- [x] Focused resolver suite passes.
- [x] Full macOS unit gate passes under warnings-as-errors.

## Commit tracking

- Implementation:
  `83a3590e3e76804f581687d9907f54e7243fa8d0`
  (`feat(runtime): resolve workload start plans`).

## Follow-on integration

The current production API service still launches one runtime VM per
container. Wiring shared-sandbox ownership into that path now would record
authority the runtime does not actually enforce. The next runtime slice must
provide the common shared-sandbox materialization path, then adapt the existing
namespace, network, storage, resource, logging, security, device, model,
root-filesystem, and engine-socket controllers to this resolver.
