# Pull request handoff: synchronize Apple `container` test fixtures

> [!IMPORTANT]
> The merge commit is signed. Preserve its parentage and verified signature
> when reviewing or transferring the fork reconciliation.

## Summary

Merge `apple/container` `main` through `f0b2b96`, adopting Apple’s typed
warmup-image fixtures and compatible `swift-collections` lock while retaining
the fork’s explicit stack provenance.

## Apple-shaped boundary

- Uses one signed merge commit whose second parent is Apple `f0b2b96`.
- Resolves only the fixture API and dependency-source overlap.
- Preserves Apple’s `WarmupImage` abstraction in all fork-only tests instead
  of adding a parallel fixture mechanism.
- Contains no Compose types, feature flags, or public runtime behavior.

## Code map

- `Package.resolved` adopts Apple’s `swift-collections` 1.5.1 resolution while
  retaining the fork Containerization source.
- `Tests/ContainerCommandsTests/TestCLIRunInitImage.swift` uses `WarmupImage`
  and retains the deterministic invalid-image regression.
- Fork-only integration tests replace removed array subscripts with
  `.alpine320`.
- Apple-owned fixture sources merge the new typed `WarmupImage` API unchanged.

## Validation

```console
make check
make test
make integration
```

- `make check` passed.
- The synchronized tree passed 1,123 tests before the follow-on network fix;
  the final combined tree passes 1,131 instrumented unit tests in 131 suites.
- The source-build integration gate passed 3 warmup tests, 238 concurrent tests
  in 27 suites, and 143 serial tests in 14 suites on the MacBook Pro.
- The downstream Compose pin runs the strict Docker Compose V2 parity matrix
  before its prerelease is published.

## PR template

### Type of change

- [x] Bug fix / compatibility maintenance
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

### Motivation and context

Align the fork’s macOS integration fixtures and lockfile with Apple’s current
source so the Compose stack validates against the same contracts Apple
maintains.

### Testing

- [x] Tested locally on macOS
- [x] Existing and fork-only tests updated
- [x] Full unit suite passed
- [x] Documentation updated
- [ ] Docker Compose V2 parity (completed in the downstream Compose pin)

## Commit tracking

- `3cab3a085a472057f3dd54c391cc4fd5c41fe36a`
  (`chore(upstream): sync Apple test fixtures`)
