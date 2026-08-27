<!-- markdownlint-disable MD013 -->

# [Parity] Explicit shared-VM container lifecycle

## Problem

The Engine-owned Linux sandbox can already host generation-fenced workloads for protected services, but ordinary `container run` and `container create` still select a dedicated VM unconditionally. Users therefore cannot trade the dedicated VM security boundary for lower repeated-start cost, and the CLI cannot durably report which isolation contract was requested or selected.

## Required behavior

- Add explicit `--isolation=shared-vm` and `--isolation=dedicated-vm` choices while retaining dedicated VM isolation when the option is omitted.
- Persist the requested choice separately from the effective choice and bind shared workloads to one stable authority-owned sandbox identity.
- Route ordinary shared workloads through the existing durable sandbox authority without launching or deregistering a per-container runtime helper.
- Generation-fence state, wait, signal, resize, statistics, process listing, service dial, pause, resume, stop, and natural-exit reclamation.
- Preserve durable, recoverable pause, resume, and stop transactions.
- Reject configurations and operations that this first shared lifecycle cannot isolate safely; never fall back to a dedicated VM or report false capability.
- Keep the shared VM alive when one workload exits or is removed.

## Acceptance evidence

- [x] Omitted isolation decodes and resolves to dedicated VM behavior.
- [x] Explicit shared and dedicated values parse into typed durable configuration.
- [x] Unsupported values and unsafe shared configurations fail before runtime bootstrap.
- [x] Shared workload control is fenced by sandbox and process generation.
- [x] Pause and resume cannot bypass their durable lifecycle transactions.
- [x] Natural exit and explicit stop reclaim only the exact shared workload generation.
- [x] API-server boot reclaims surviving effectless shared workloads before recovered lifecycle state becomes reachable.
- [x] Shared workload boot and cleanup never own a per-container launchd service.
- [x] A missing shared authority or mismatched durable sandbox identity fails without fallback.
- [x] The guest wait deadline controls graceful-stop escalation before `SIGKILL`.
- [x] The focused 16-test set, strict format lint, Markdown lint, and diff review pass before pull-request publication.
- [ ] The exact reviewed pull-request head is merged.

## Initial supported surface

The first vertical supports native Linux workloads using exactly `--network none` or `--network host`, initial process streams, and the ordinary state, wait, pause, resume, statistics, process-list, stop, and remove lifecycle. Host networking deliberately shares the VM network namespace; private user, PID, cgroup, IPC, and UTS namespaces remain mandatory.

Attach after start, exec, copy, runtime log following, health checks, published TCP/UDP ports, bridge/custom networking, custom kernel or init assets, Rosetta, devices, GPUs, nested virtualization, privileged workloads, host namespace escapes, and live snapshots remain explicit follow-ons. This slice does not close the broader sandbox-authority parity contract.

## Tracking

- Parent issue: [`stephenlclarke/container#113`](https://github.com/stephenlclarke/container/issues/113).
- Containerization authority issue: [`stephenlclarke/containerization#23`](https://github.com/stephenlclarke/containerization/issues/23).
- Compose performance parent: [`stephenlclarke/container-compose#278`](https://github.com/stephenlclarke/container-compose/issues/278).

<!-- markdownlint-enable MD013 -->
