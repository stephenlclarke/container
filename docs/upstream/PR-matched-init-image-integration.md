# Pull request: use the matched guest for CPU cgroup integration

## Summary

- Select `vminit:latest` in the CPU-limit and CPU-share checks in
  `TestCLIRunCommand`.
- Continue testing the existing `--cpus`, CPU quota/period, and
  `--cpu-shares 512` commands with their cgroup v2 assertions.
- Preserve the versioned production default guest image.

## Apple-shaped boundary

This is a narrow `apple/container` integration-test correction. The existing
integration setup builds and installs `vminit:latest` from the same source
revision, so the test now exercises the runtime it intends to validate. No
Compose code or product behavior changes.

## Code map

- `Tests/IntegrationTests/Run/TestCLIRunCommand.swift`: add
  `--init-image vminit:latest` only to CPU cgroup runtime assertions.

## Validation

```sh
swift build --build-tests
swift test --skip-build --filter 'TestCLIRunCommand/testRunCommandCPUShares'
make coverage-unit
make check
```

Five focused CPU cgroup cases passed using the source-matched guest, including
integer, fractional, and unlimited CPU limits, CPU shares, and CPU
quota/period. The source-build primary CLI pass also completed 233 tests in 26
suites with those cases included. `coverage-unit` passed 1,085 tests in 128
suites and `make check` passed formatting and license checks.

The all-in-one integration target still reaches an independent Phase 5 builder
test failure involving an external Dockerfile path with `/tmp` and
`/private/tmp` canonicalization. It is not changed or masked by this slice and
is recorded for the ordered Phase 5 build work. Docker Compose parity is not
applicable because this does not change a runtime or Compose feature; the
release gate subsequently validates Compose against the pinned runtime stack.

## Compatibility and risks

The product default guest remains versioned. This change affects one
source-build integration assertion and makes it deterministic with respect to
the code being tested. The only remaining risk is an independently broken
`vminit:latest` build, which the integration setup and focused test surface
directly.

## Commit tracking

- `container` implementation and regression coverage:
  `e22d2e1e4fa7eb105c06583333bfebab9babe64f`
  (`test(integration): use matched guest for CPU cgroups`).
- No `containerization` change is required.
