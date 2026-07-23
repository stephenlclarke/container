# Pull request handoff: synchronize Apple `container` main through `78e2cb44`

## Summary

Record Apple `container` `main` through `78e2cb44` without introducing a
second runtime implementation. Apple's only new patch is already present in
the fork as signed commit `0fe7833`, so the signed merge is intentionally
source-empty relative to the fork's previous `main`.

## Apple-shaped boundary

- Uses one signed merge commit to retain Apple ancestry.
- Keeps Apple's logger calls exactly as merged in apple/container#1889.
- Adds no public command, API, launchd, configuration, or guest-runtime change.
- Leaves fork-specific package provenance and Compose abstractions untouched.
- Requires the downstream Compose pin and parity gates to publish the new
  ancestry commit.

## Code map

- `Sources/ContainerCommands/System/SystemStart.swift`
  - existing fork commit `0fe7833` contains the two logger substitutions;
  - Apple commit `78e2cb4` now contains the same substitutions;
  - merge commit `d24be8a` introduces no first-parent source diff.
- `docs/upstream/ISSUE-apple-main-sync-20260723.md`
  - records equivalence, scope, reproduction, and validation.
- `docs/upstream/PR-apple-main-sync-20260723.md`
  - provides this upstream-ready handoff.

## Validation

```sh
swift test --disable-automatic-resolution --filter SystemStartTests
make check
make test
git diff --exit-code 271ba58e88844f3d3708d25eb584e6b4ae441ed5..d24be8a91ea82baa27f9546e82897e52dcc6862b
```

The merge adds no executable lines, so it has no new uncovered code. The full
fork suite remains the regression gate. Docker Compose V2 parity is performed
after the downstream Compose repository pins this exact Container commit.

Verified on this Apple-silicon Mac:

- focused `SystemStartTests`: 2/2 passed;
- `make check`: Swift formatting and Hawkeye license checks passed;
- `make test`: 1,134 Swift tests in 131 suites passed, plus 94 XCTest
  cases;
- the first-parent no-code-delta check passed.

## PR template

### Type of change

- [x] Upstream maintenance
- [x] Documentation update
- [ ] New feature
- [ ] Breaking change

### Motivation and context

Keep the macOS fork's ancestry current with Apple while retaining the
already-shipped, Apple-shaped implementation of apple/container#1889.

### Testing

- [x] Focused `SystemStartTests`
- [x] Fork formatting and static checks
- [x] Full fork unit suite
- [x] First-parent no-code-delta check
- [ ] Downstream Compose unit and live integration suites
- [ ] Docker Compose V2 parity

## Commit tracking

- Existing equivalent implementation:
  `0fe78339ac28d6fca33eeaa94bfd1f09aa772529`.
- Apple upstream:
  `78e2cb4417640ff2d630c407a1d00ef09c9d3334`.
- Signed ancestry merge:
  `d24be8a91ea82baa27f9546e82897e52dcc6862b`.
