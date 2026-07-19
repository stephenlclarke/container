# Pull request handoff: align vmexec namespace runtime provenance

## Summary

- Advance Container's pinned `containerization` dependency to the signed
  vmexec namespace-entry repair handoff tip.
- Regenerate `Package.resolved` from that published remote revision.
- Preserve a reproducible Container package graph for the matched runtime
  bundle without changing Container behavior or APIs.

## Type of change

- [x] Build and dependency metadata
- [x] Documentation update
- [ ] Runtime API change
- [ ] Docker or Compose compatibility surface

## Motivation and context

The lower runtime now avoids an invalid Linux `setns` reentry when a target
workload already uses vmexec's current user namespace. Container must build
the reviewed guest source rather than the earlier dependency revision, or a
matched release can retain the privileged/default execution failure despite a
completed lower-fork repair.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Generic vmexec namespace behavior and tests. |
| `apple/container` | No API or policy change; consumes the fixed revision. |
| `container-compose` | Owns Docker parsing, tests, and release provenance. |

This pin-only change is not an Apple upstream pull request. Any future
upstream Container dependency update must use the accepted Apple revision and
must not carry this fork URL or hash.

## Code map

- `Package.swift` declares
  `422302c9490f337ebfad0b17b9542de97bde9e34`.
- `Package.resolved` locks the resolver to the same revision and records its
  resulting origin hash.

## Commit tracking

- Containerization implementation:
  `fe896b6511d9fe0f0b8d3d25d3a8d8a1ed5ab5a1`
  (`fix(vmexec): avoid reentering the current user namespace`).
- Containerization handoff tip:
  `422302c9490f337ebfad0b17b9542de97bde9e34`
  (`docs(handoff): add vmexec namespace-entry repair`).
- Container provenance update:
  `1e8b8f57df4e7e43adb85db842c16e242e0f3f04`
  (`chore(deps): align vmexec namespace runtime revision`).

## Validation

```console
swift package resolve
make build
make test
make check
git diff --check
```

All commands pass locally on macOS against the published lower revision. The
lower fork's unit coverage and its matched Compose YAML guest regressions
remain the behavior coverage; this pin-only change adds no Container branch.

## Review checklist

- [x] The pin is an immutable published revision.
- [x] `Package.swift` and `Package.resolved` agree.
- [x] The change does not expand Container's public API or policy surface.
- [x] The commit uses a Conventional Commit subject and verified signature.
- [x] The upper Compose provenance update remains a separate minimal slice.
