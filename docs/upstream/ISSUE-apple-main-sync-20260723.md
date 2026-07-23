# Upstream sync: Apple `main` through `78e2cb44`

## Context

Apple `container` advanced by one macOS-relevant commit after the fork's last
sync:

- `78e2cb4417640ff2d630c407a1d00ef09c9d3334`
  (`Use log instead of print for system start status messages (#1889)`).

The fork already carried the same two source changes in the signed,
Apple-shaped commit:

- `0fe78339ac28d6fca33eeaa94bfd1f09aa772529`
  (`fix(system): route startup status through logger`).

That earlier fork commit references Apple issues #1888 and #1889 and keeps the
interactive kernel-install prompt on standard output while routing only status
messages through the command logger.

## Required behavior

- Record Apple `main` through `78e2cb44` in the fork's ancestry.
- Do not duplicate or reshape the already-equivalent runtime implementation.
- Preserve all fork-specific Containerization, builder-shim, packaging, and
  Compose provenance.
- Validate the merged tree on macOS before updating the Compose stack pin.

## Reproduction

Before the merge, both trees contained these statements in
`Sources/ContainerCommands/System/SystemStart.swift`:

```swift
log.info("Verifying machine API server is running...")
log.warning("No default kernel configured.")
```

`git range-diff 0fe7833^..0fe7833 78e2cb4^..78e2cb4` confirms that the only
implementation difference is surrounding context from later
`installDefaultKernel` work. The signed merge therefore has no first-parent
source diff.

## Validation gate

```sh
swift test --disable-automatic-resolution --filter SystemStartTests
make check
make test
git diff --exit-code 271ba58e88844f3d3708d25eb584e6b4ae441ed5..d24be8a91ea82baa27f9546e82897e52dcc6862b
```

Verified on this Apple-silicon Mac:

- focused `SystemStartTests`: 2/2 passed;
- `make check`: Swift formatting and Hawkeye license checks passed;
- `make test`: 1,134 Swift tests in 131 suites passed, plus 94 XCTest
  cases;
- the first-parent no-code-delta check passed.

The downstream Compose stack must update its exact Container pin and complete
its unit, live integration, Docker Compose V2 parity, Sonar, release, and
Homebrew gates before this sync is declared current.

## Commit tracking

- Existing equivalent implementation:
  `0fe78339ac28d6fca33eeaa94bfd1f09aa772529`.
- Apple upstream:
  `78e2cb4417640ff2d630c407a1d00ef09c9d3334`.
- Signed ancestry merge:
  `d24be8a91ea82baa27f9546e82897e52dcc6862b`.
