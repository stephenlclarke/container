# Pull request handoff: make ContainerTestSupport package-buildable

## Summary

Make Apple Container's public `ContainerTestSupport` product buildable when
Swift Testing is unavailable to production targets. This fixes the prebuilt
runtime-package failure introduced by the fixture extraction in
[Apple Container PR #1887](https://github.com/apple/container/pull/1887).

## Apple-shaped boundary

The patch is deliberately confined to the support module and its test target:

- no Container runtime or service behavior changes;
- no Compose-specific code in Apple Container;
- no change to the public support product or its downstream import path; and
- no fallback dependency, vendored framework, or platform-specific shim.

The existing `CommandError` surface is used for assertion failures, and
`canImport(Testing)` preserves the richer test metadata where Apple Swift
Testing is available.

## Code map

| Path | Change |
| --- | --- |
| `Sources/ContainerTestSupport/ContainerFixture.swift` | Guards Swift Testing and provides a production-safe fixture identity fallback. |
| `Sources/ContainerTestSupport/BuildFixture.swift` | Reports file-assertion failures through `CommandError`. |
| `Sources/ContainerTestSupport/ContainerFixture+ImageHelpers.swift` | Reports image-assertion failures through `CommandError`. |
| `Sources/ContainerTestSupport/ContainerFixture+MachineHelpers.swift` | Removes an unused Swift Testing import. |
| `Package.swift` | Registers the focused support-module test target. |
| `Tests/ContainerTestSupportTests/ContainerTestSupportTests.swift` | Covers helper success and all error results through a fake CLI. |
| `Makefile` | Makes the full macOS test and coverage gate deterministic by default. |

## Validation

```console
swift test -c debug --filter ContainerTestSupportTests
make BUILD_CONFIGURATION=release build
make test
make check
make coverage-unit
```

- The focused test passes.
- The release package build passes with Swift 6.3.3 on macOS 26.
- `make test` passes 1,124 tests in 130 suites after serializing the shared
  test process.
- `make check` passes formatting and license validation.
- `make coverage-unit` passes 1,124 tests in 130 suites (38.57% lines,
  40.31% functions, 40.38% regions).

No Compose source or runtime pin changes are included in this source-fork
fix. Docker Compose V2 parity will be exercised when the Compose fork pins
the published runtime commit.

## PR template

### Type of change

- [x] Bug fix
- [x] Test coverage/buildability fix
- [x] Test-harness reliability fix
- [x] Documentation update
- [ ] Breaking change

### Motivation and context

Release packaging builds public products, including `ContainerTestSupport`.
That product must not require Swift Testing merely to compile. Its assertion
helpers should also report errors through the library's normal error channel
instead of a test-only macro.

### Testing

- [x] Reproduced the hosted macOS prebuilt failure
- [x] Focused assertion behavior test added
- [x] Production release build passed
- [x] Full repository test gate passed
- [x] Unit coverage target passed
- [x] Formatting and license checks passed
- [ ] Docker Compose V2 parity (not applicable to this source-only change)

## Commit tracking

- `8575aacfb6fedff56366e8fcf7a825f7b0a61f71`
  (`fix(tests): build test support without testing`)
