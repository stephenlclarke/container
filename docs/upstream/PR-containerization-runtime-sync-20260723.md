# Pull request handoff: update the Containerization runtime pin

## Proposed pull request

`build(deps): update Containerization runtime`

This handoff covers the signed dependency commit
[`8cf9468b861306a801c56924e591e98f39f771e8`](https://github.com/stephenlclarke/container/commit/8cf9468b861306a801c56924e591e98f39f771e8).

## Summary

Update Container's immutable Containerization dependency from `9a3c5b4d` to
`9097a24d`. The selected runtime includes Apple's cloud-hypervisor virtiofs
hotplug update and the Apple-shaped VM-start cleanup fix.

## Apple-shaped boundary

- Changes only the existing dependency constants.
- Uses one immutable revision in both package manifests.
- Keeps the existing environment override abstraction unchanged.
- Adds no Container, Docker, Compose, or host-platform behavior.
- Validates host binaries and a freshly rebuilt guest init image together.

## Code map

- `Package.swift`
  - updates the default `containerizationRevision`;
  - retains `CONTAINERIZATION_SOURCE` and `CONTAINERIZATION_VERSION`
    overrides.
- `Package.resolved`
  - records the same exact Containerization revision.
- `docs/upstream/ISSUE-containerization-runtime-sync-20260723.md`
  - records the dependency gap, validation, and commit boundary.
- `docs/upstream/PR-containerization-runtime-sync-20260723.md`
  - provides this handoff.

## Validation on macOS

```console
swift package resolve
make check
make test
make coverage
```

Results:

- `swift package resolve` changed no dependency other than the requested
  Containerization revision.
- Formatting and license checks passed.
- The normal unit target passed 1,134 tests in 131 suites, plus XCTest.
- Instrumented unit coverage passed 1,135 tests in 131 suites.
- Live coverage passed 1 warmup test, 238 concurrent tests in 27 suites, and
  143 serial tests in 14 suites.
- Combined coverage reached 51.58% lines, 50.01% functions, and 51.44%
  regions.

## Compatibility and risks

No Container executable source changes. The package graph remains pinned and
reproducible. The full live coverage gate rebuilt `vminit:latest` from
`9097a24d`, preventing host/guest runtime skew.

This exact fork-URL pin is downstream release provenance and is not itself an
Apple upstream candidate. The functional VM cleanup is independently isolated
in the Containerization handoff for Apple issue #804.

## PR template

### Type of change

- [x] Dependency maintenance
- [x] Runtime provenance update
- [x] Documentation update
- [ ] New feature
- [ ] Breaking change

### Motivation and context

Ensure Container and downstream Compose builds consume the already-validated
Containerization runtime rather than silently packaging the previous pin.

### Testing

- [x] Package resolution reproduced
- [x] Formatting and license checks passed
- [x] Full unit suite passed
- [x] Full combined coverage target passed
- [x] Fresh guest init image exercised
- [ ] Docker Compose V2 parity (owned by the downstream Compose slice)

Related issue handoff:
`docs/upstream/ISSUE-containerization-runtime-sync-20260723.md`.
