# Pull request handoff: synchronize Phase 1 runtime provenance

## Summary

- Advance the pinned `containerization` dependency to the signed Phase 1
  handoff tip.
- Regenerate `Package.resolved` from the remote dependency.
- Preserve a reproducible, immutable Container package graph for the matching
  Compose release stack.

## Type of change

- [x] Build and dependency metadata
- [x] Documentation update
- [ ] Runtime API change
- [ ] Docker or Compose compatibility surface

## Motivation and context

The prior pin predated the generic shared-sandbox namespace policy and the
formatter correction needed by the release validation path. A current artifact
must identify the runtime code it actually builds, so this change advances the
pin without adding product behavior in Container.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Generic typed namespace policy; separate handoff. |
| `apple/container` | No API change; consumes an immutable runtime revision. |
| `container-compose` | Owns Docker parsing and release stack provenance. |

This fork commit is intentionally not an upstream Apple pull request. If the
lower-runtime proposal is accepted, an upstream follow-up must use its Apple
revision and must not include the `stephenlclarke` dependency URL or hash.

## Code map

- `Package.swift` declares the exact runtime revision.
- `Package.resolved` locks the resolver to that same revision.

## Validation

```sh
swift package resolve
make build
make test
make check
git diff --check
```

The lower-runtime source change retains its focused macOS guest integration
coverage for private user namespaces. This pin-only change adds no Container
runtime branch, so it does not require a new Docker Compose fixture.

## Commit tracking

- Lower-runtime implementation:
  `89aa0eb6fb451875b73e4f4322a735b740e3cc2a`
  (`feat(pod): add typed shared namespace policy`).
- Lower-runtime formatter and handoff tip:
  `2d7ae6c01227d4c95a5f44fdc9768070923ee335`.
- Container fork implementation:
  `afca50264757864111106c91d44d4599b8e7a340`
  (`chore(deps): align phase one runtime revision`).

## Remaining risks

The generic lower-runtime policy does not create a durable, per-container
sandbox membership API. Docker Compose service/container namespace sharing
therefore remains intentionally unavailable until that Apple-shaped primitive
exists.
