<!-- markdownlint-disable MD013 -->

# [Parity] Native inspect must resolve stable lifecycle identities

## Problem

The atomic lifecycle view exposes an immutable 64-character container ID, a canonical name, and an immutable native bundle key. `container inspect` previously filtered the legacy resource list by bundle key only, so an immutable ID returned by `compose ps -q` failed with `container not found` even though the container was running.

## Required behavior

- Resolve an exact immutable lifecycle ID, canonical name, or native bundle key to one container.
- Read resource and lifecycle identity from one atomic lifecycle-view revision.
- Preserve native bundle keys for runtime operations and reject unknown identities.

## Acceptance evidence

- [x] Focused resolver tests cover all three identities, duplicate aliases, and an unknown identity.
- [x] The focused Compose host-namespace fixture accepts `compose ps -q` output in `container inspect`, verifies the live default-network attachment, and completes teardown.
- [ ] Exact release-build performance and coherent-stack gates run after the functional slice is merged.

Tracking issue: [`stephenlclarke/container#120`](https://github.com/stephenlclarke/container/issues/120).

Related pull-request handoff: `docs/upstream/PR-135.md`.

<!-- markdownlint-enable MD013 -->
