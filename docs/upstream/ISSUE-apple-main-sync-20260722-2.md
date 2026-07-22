# Upstream sync: Apple `main` through `f0b2b96`

## Context

The Container fork diverged from `apple/container` after Apple merged two
maintenance commits on 22 July 2026. The first returns `swift-collections` to
the compatible 1.5.1 resolution; the second replaces an untyped warmup-image
array with the `WarmupImage` enum used by integration tests.

Keeping these test and dependency contracts aligned is required before the
Compose stack can publish another macOS prerelease.

## Required behavior

- Merge Apple `main` through `f0b2b96` without rewriting Apple history.
- Preserve the fork's Containerization source pin and Builder shim provenance.
- Adopt the typed warmup-image API throughout the fork's additional macOS
  integration tests.
- Retain deterministic invalid-image construction where the fork deliberately
  tests init-image rejection.
- Make no Compose-specific runtime change as part of the synchronization.

## Apple upstream inputs

- `968dbe4`: downgrade `swift-collections` to 1.5.1.
- `f0b2b96`: replace the warmup fixture array with `WarmupImage`.

## Reconciliation

Seven fork-only integration references now use `.alpine320`. The init-image
validation regression continues to create a deliberately invalid local image
instead of treating a valid warmup fixture as invalid. The dependency lockfile
adopts Apple’s 1.5.1 resolution while the fork-specific Containerization source
selection is unchanged.

## Validation

```console
make check
make test
make integration
```

- Formatting and license checks passed.
- The synchronized source passed 1,123 tests before the privileged-port
  regression work was layered on top.
- The combined tree passed 1,131 instrumented unit tests in 131 suites.
- The final source-build integration gate passed 3 warmup tests, 238 concurrent
  tests in 27 suites, and 143 serial tests in 14 suites on the MacBook Pro.

## Commit tracking

- `3cab3a085a472057f3dd54c391cc4fd5c41fe36a`
  (`chore(upstream): sync Apple test fixtures`)
