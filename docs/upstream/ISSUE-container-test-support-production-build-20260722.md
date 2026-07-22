# Upstream regression: public test support breaks production package builds

## Context

Apple Container [PR #1887](https://github.com/apple/container/pull/1887)
extracted `ContainerFixture` into the public `ContainerTestSupport` product.
The product is useful to downstream test targets, but its implementation
unconditionally imports the Swift Testing module and uses `Test.current` and
`#expect` in production source files.

The release packaging path builds every public library target. On the macOS
release runner, Swift Testing is not available to a non-test target, so the
new product prevents the runtime package from building even though it is only
intended to support tests.

## Reproduction

The failure was reproduced by the Compose prebuilt release job for commit
`96e33b21`:

```console
make -C container BUILD_CONFIGURATION=release build
```

The runner reports:

```text
Sources/ContainerTestSupport/BuildFixture.swift:21:8: error: no such module 'Testing'
```

The failed job is
[Build prebuilt binaries #29892531597](https://github.com/stephenlclarke/container-compose/actions/runs/29892531597).
The same production build succeeds after this change with Swift 6.3.3 on
macOS 26.

## Resolution

- Import Swift Testing only when the toolchain makes it available.
- Retain the detailed current-test identity when Swift Testing is present;
  fall back to the fixture identifier when it is not.
- Replace public assertion helpers' `#expect` calls with the existing
  `CommandError.executionFailed` error channel, so callers can use the module
  from any target.
- Add a focused test target that exercises success and every assertion failure
  path with a fake `container` executable.
- Run the repository test command serially by default. The full Swift Testing
  suite consistently aborts on macOS when loopback socket tests run alongside
  unrelated descriptor-owning tests; `--no-parallel` makes the documented
  `make test` and coverage gates deterministic while allowing callers to
  override `SWIFT_TEST_FLAGS` when parallel execution is safe.

## Scope

This is a buildability and test-harness correction only. It does not alter
Container runtime behavior, the public shape of `ContainerTestSupport`, the
Compose layer, or Docker Compose V2 behavior.

## Validation

```console
swift test -c debug --filter ContainerTestSupportTests
make BUILD_CONFIGURATION=release build
make test
make check
make coverage-unit
```

All commands pass on macOS. The full and instrumented test gates each execute
1,124 tests in 130 suites. Unit coverage is 38.57% lines, 40.31% functions,
and 40.38% regions.

## Commit tracking

- `8575aacfb6fedff56366e8fcf7a825f7b0a61f71`
  (`fix(tests): build test support without testing`)
