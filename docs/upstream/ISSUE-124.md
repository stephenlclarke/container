<!-- markdownlint-disable MD013 -->

# [Parity] Concurrent container bootstrap

## Problem

`ContainersService.bootstrap` held the host-wide service lock while it validated logging, resolved networking, registered the runtime service, created the runtime client, and booted the VM. Compose could request multiple independent starts concurrently, but the API server serialized the expensive VM bootstrap phase across container IDs.

## Required behavior

- Keep same-ID start, attach, restart, stop, and removal operations serialized by the existing per-container lifecycle mutation.
- Allow distinct container IDs to perform independent runtime bootstrap work concurrently.
- Prevent a delayed bootstrap from committing into a replacement container or a newer lifecycle operation.
- Preserve logging, exit-monitor, launchd, and runtime-token cleanup when bootstrap fails.
- Retain monotonic per-phase timing evidence without adding release-path info logging.

## Acceptance evidence

- [x] Focused generation-fence tests cover container replacement and lifecycle-operation replacement.
- [x] Focused logging authority and lifecycle validation tests pass.
- [x] A warnings-as-errors release build succeeds.
- [x] Seven-repetition release evidence shows 10-service median startup improving from 5.244s to 1.611s and 50-service median startup improving from 25.742s to 16.411s.
- [x] Functional Docker parity passes for 1, 10, and 50-service startup and teardown.
- [ ] The parent performance contract remains open because 50-service startup P95 is still 11.77x Docker.

## Scope

This slice removes one host-wide bootstrap serialization point. It does not claim that Container authority, provider, storage, logging, or lifecycle performance is fully comparable with Docker.

Tracking issue: [`stephenlclarke/container#124`](https://github.com/stephenlclarke/container/issues/124).

Parent contract: [`stephenlclarke/container-compose#278`](https://github.com/stephenlclarke/container-compose/issues/278).

Related pull-request handoff: `docs/upstream/PR-143.md`.

<!-- markdownlint-enable MD013 -->
