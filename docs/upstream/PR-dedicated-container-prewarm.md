<!-- markdownlint-disable MD013 -->

# Pull request handoff: prewarm dedicated containers after create

## Type of change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and context

Dedicated containers currently perform their complete VM bootstrap on the first foreground start or pre-start attach. Compose can create several durable containers before starting them, leaving safe preparation time unused and placing VM setup on the user-visible critical path. This change asynchronously prepares an eligible built-in dedicated runtime only after the durable create commit, without starting init or changing the selected isolation.

## Implementation

- Schedule preparation for stopped, never-started `dedicated-vm` containers that use the built-in Linux runtime and do not forward SSH agent input.
- Serialize background preparation with start, attach, removal, and recovery through the existing per-container lifecycle boundary.
- Give a prewarming runtime a server-owned deferred standard-input relay, then replace it with the first foreground client's stream before starting init.
- Finish the deferred input relay with end-of-file when the first foreground client has no stdin.
- Discard an unreachable prepared runtime and retry the same foreground bootstrap cold instead of retaining a dead client.
- Retain the prepared client as a cleanup tombstone until logging cleanup and runtime-service deregistration are both confirmed, so retries cannot miss a surviving mounted VM.
- Retain per-step logging-abort progress after a transient failure, allowing cleanup to resume without repeating completed pipe, writer, or configuration work.
- Rebuild a prepared VM after stopped-container CPU or memory updates so the runtime matches the durable configuration.
- Rebuild a prepared VM after a stopped-container rename so remote logging metadata matches the new canonical name.
- Serialize stopped rootfs export and logging handoff with preparation, discarding the prepared VM before either operation reads or changes durable state.
- Consume preparation on Docker restart and run confirmed prepared-runtime cleanup before deletion can remove the bundle.
- Reject ordinary attach and exec creation until the container is publicly running or paused, even though a prepared runtime is already booted.
- Cleanly stop a booted prepared VM before deregistering its runtime helper, propagating reachable stop failures so the cleanup tombstone remains retryable while allowing an already-completed shutdown to resume deregistration.
- Recover eligible durable containers after API-server restart and clean partial runtime state after a background failure so foreground start can retry cold.
- Preserve the default dedicated isolation, explicit shared isolation, custom runtime contract, and fail-closed isolation parsing.

## Testing

- [x] Focused eligibility tests cover dedicated, shared, SSH, custom-runtime, already-started, and running containers.
- [x] Focused runtime tests cover deferred standard input and the exact runtime states that accept foreground attachment.
- [x] Focused regressions cover deferred-input EOF, resource/rename invalidation, logging-handoff control, retryable runtime/logging cleanup, and stopped-container attach/exec rejection.
- [x] Release-mode warning-as-error builds pass for the API server, Linux runtime, CLI, and VM networking helper.
- [x] A signed runtime proof confirms preparation does not start init and foreground start consumes the prepared runtime.
- [x] A signed export regression confirms a prepared VM is stopped before its ext4 root filesystem is read.
- [x] Signed deletion and Docker-restart regressions confirm helper shutdown and prepared-runtime reuse.
- [x] Dedicated, omitted-isolation, shared-isolation, invalid-isolation, and SSH controls retain their contracts.
- [ ] Exact pull-request-head review reports no unresolved finding.

The signed proof recorded 1.025 and 1.048 seconds of dedicated VM bootstrap in the background. `container start` then completed in 0.10 and 0.13 seconds, reusing the same runtime-helper process observed after preparation. Each prepared container retained a distinct VM boot ID; the omitted-isolation control used a third identity. Init marker files remained absent until explicit start, SSH forwarding did not prewarm, `shared-vm` completed through its existing lifecycle, and an invalid isolation value failed closed.

A signed follow-up regression proof started a stdin-reading workload without an input handle and observed clean EOF. It then killed the prepared runtime helper before start; the API server discarded PID 6470, bootstrapped a cold replacement at PID 6509, and completed the workload instead of retaining the dead client.

The final signed regression exported a valid Alpine root filesystem after preparation, verified `etc/alpine-release` in the archive, and confirmed that runtime helper PID 31310 was no longer active after export. Deletion likewise stopped prepared helper PID 31379 before removing the bundle. Docker restart reused prepared helper PID 31422, delivered deferred stdin EOF, and completed the workload. Subsequent signed XPC regressions rejected exec creation and ordinary attach while the container remained publicly stopped without discarding the prepared helper; the attach proof retained PID 59403. A clean-shutdown export then stopped prepared helper PID 61511 before reading a valid Alpine archive. Thirty-seven focused lifecycle, concurrency, runtime attach/shutdown, invalidation, and retryable-cleanup tests passed, together with the seven logging-handoff control tests, followed by warning-as-error release builds for the API server and Linux runtime.

## Compatibility

Omitted isolation remains `dedicated-vm`, and every dedicated container keeps a private VM. `shared-vm` remains an explicit experimental opt-in and is never selected as a fallback. SSH forwarding and custom runtime plugins retain cold foreground bootstrap because their start-time input contracts cannot safely be anticipated. Background failure is recoverable and does not make container creation fail.

## Links

- Closes [`stephenlclarke/container#149`](https://github.com/stephenlclarke/container/issues/149).
- Pull request: [`stephenlclarke/container#150`](https://github.com/stephenlclarke/container/pull/150).
- Parent isolation issue: [`stephenlclarke/container#113`](https://github.com/stephenlclarke/container/issues/113).
- Bootstrap pressure control: [`stephenlclarke/container#144`](https://github.com/stephenlclarke/container/pull/144).
- Compose performance issue: [`stephenlclarke/container-compose#278`](https://github.com/stephenlclarke/container-compose/issues/278).
- Compose client reuse: [`stephenlclarke/container-compose#327`](https://github.com/stephenlclarke/container-compose/pull/327).

<!-- markdownlint-enable MD013 -->
