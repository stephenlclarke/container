<!-- markdownlint-disable MD013 -->

# [Parity] Prewarm dedicated containers without weakening isolation

## Problem

A dedicated container currently pays its full VM bootstrap cost only when the first start or pre-start attach arrives. Compose can prepare many durable containers before starting them, so this sequencing leaves safe overlap unused and keeps cold-start latency on the user-visible critical path.

## Required behavior

- After the durable create commit, asynchronously prewarm eligible `dedicated-vm` containers without starting the init process.
- Preserve `dedicated-vm` as the omitted-isolation default and keep every prewarmed container in its own VM.
- Leave `shared-vm` on its existing shared-sandbox lifecycle; prewarming must never change or fall back from the selected isolation.
- Limit prewarming to the built-in `container-runtime-linux` runtime. Custom runtime plugins retain their existing bootstrap contract.
- Let the first real bootstrap or pre-start attach supply client-owned standard streams before process start.
- Skip dedicated prewarming when caller-owned dynamic input is required, initially SSH agent forwarding.
- Serialize prewarm, start, attach, remove, and recovery through the existing per-container lifecycle boundary.
- Treat background prewarm failure as recoverable: clean partial runtime state and let the later foreground start retry cold.
- Retain failed cleanup as retryable prepared state until the runtime helper is confirmed inactive.
- Retain successful logging-abort steps across cleanup retries after a transient failure.
- Discard a prepared runtime that becomes unreachable before start and retry the foreground bootstrap cold.
- Rebuild a prepared VM after stopped-container CPU or memory updates.
- Rebuild a prepared VM after a stopped-container rename so logging metadata uses the new canonical name.
- Quiesce prepared VMs before stopped rootfs export or logging handoff operations.
- Consume preparation when Docker restarts a never-started container, and confirm cleanup before deleting a prepared container.
- Reject ordinary attach and exec creation while a prepared container remains publicly stopped.
- Cleanly stop a booted prepared VM before deregistering its runtime helper, retain reachable cleanup failures for retry, and resume deregistration after shutdown has already completed.
- Resume eligible never-started prewarming after API-server recovery.

## Acceptance evidence

- [x] Focused tests cover dedicated-only eligibility, SSH and custom-runtime exclusion, deferred standard input, and attachable runtime states.
- [x] Exact signed runtime proof shows create returns before background preparation completes, the init process does not start early, first start uses the prewarmed dedicated VM, and a second dedicated container has a different VM identity.
- [x] Shared and omitted isolation retain their established contracts and invalid values still fail closed.
- [x] A release-mode targeted comparison records create-to-start latency without attributing unrelated stack changes.
- [ ] The final pull-request head passes exact review with no unresolved finding and is merged.

The signed release-mode proof recorded background bootstrap durations of 1.025 and 1.048 seconds. The corresponding foreground starts completed in 0.10 and 0.13 seconds while retaining the same runtime-helper process across preparation and start. The two prewarmed containers had distinct VM boot IDs, the omitted-isolation control used a third boot ID, and no init marker appeared before an explicit start. SSH forwarding remained cold, `shared-vm` completed through its existing lifecycle, and an invalid isolation value failed closed.

A follow-up signed regression proof confirmed that a stdin-reading process receives EOF when started without an input handle. Killing the prepared runtime helper before start also caused a cold replacement to be created and the workload to complete successfully. The final signed proof exported a valid Alpine root filesystem from a prepared container, confirmed that export and deletion stopped their runtime helpers, and showed that Docker restart reused the prepared helper while delivering deferred stdin EOF. Signed XPC regressions also confirmed that exec creation and ordinary attach are rejected while a prepared container remains publicly stopped without discarding its prepared helper. A clean-shutdown export stopped the booted helper before reading a valid Alpine archive, and focused regressions confirmed that reachable shutdown failures remain retryable, already-completed shutdown resumes deregistration, rename rebuilds logging metadata, and logging-abort retry retains and resumes its incomplete run.

## Pull-request provenance

The implementation and benchmark evidence were merged in
[`stephenlclarke/container#150`](https://github.com/stephenlclarke/container/pull/150).
As of 28 August 2026, no Apple upstream pull request contains dedicated-container
prewarming.

## Related work

- Tracking issue: [`stephenlclarke/container#149`](https://github.com/stephenlclarke/container/issues/149).
- Parent isolation contract: [`stephenlclarke/container#113`](https://github.com/stephenlclarke/container/issues/113).
- Pre-start attach regression: [`stephenlclarke/container#71`](https://github.com/stephenlclarke/container/issues/71).
- Bootstrap pressure control: [`stephenlclarke/container#144`](https://github.com/stephenlclarke/container/issues/144).
- Compose performance contract: [`stephenlclarke/container-compose#278`](https://github.com/stephenlclarke/container-compose/issues/278).
- Compose client reuse contribution: [`stephenlclarke/container-compose#327`](https://github.com/stephenlclarke/container-compose/pull/327).

<!-- markdownlint-enable MD013 -->
