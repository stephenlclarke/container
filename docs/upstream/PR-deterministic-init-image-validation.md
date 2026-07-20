# Pull request: make init-image validation integration deterministic

## Summary

- Replace the remote nonexistent-image test input with an invalid OCI image
  reference.
- Exercise the same `container run` and `container create` error paths.
- Make the test finish locally without contacting DNS or a registry.

## Apple-shaped boundary

This is an `apple/container` integration-test-only correction. It uses the
existing OCI reference validation path and does not modify the runtime, API,
or Compose layer.

## Code map

- `Tests/IntegrationTests/Run/TestCLIRunInitImage.swift`: use the shared
  invalid reference in the `run` and `create` negative cases and name those
  cases for the validation they assert.

## Validation

```sh
make build-tests
swift test --skip-build --filter 'TestCLIRunInitImage/'
make coverage-unit
make check
```

The focused integration run passed all four cases: both invalid-reference
cases, help text, and explicit-default-init-image behavior. It completed
without a registry request. The source-build primary CLI pass also completed
233 tests in 26 suites with these cases included. `coverage-unit` passed 1,085
tests in 128 suites and `make check` passed formatting and license checks.

The all-in-one integration target still reaches an independent Phase 5 builder
test failure involving an external Dockerfile path with `/tmp` and
`/private/tmp` canonicalization. It is not changed or masked by this slice and
is recorded for the ordered Phase 5 build work. Docker Compose parity is not
applicable because this does not change a runtime or Compose feature; the
matched-stack release gate subsequently validates Compose against this runtime
build.

## Compatibility and risks

Valid remote image references retain their existing fetch behavior. This only
removes an external dependency from a negative validation test, so it cannot
alter a user's image-pull behavior or stored state.

## Commit tracking

- `container` integration regression coverage:
  `c10bf26ef8e8c900c929c10e6673457bdff523be`
  (`test(integration): make init image validation deterministic`).
- No `containerization` change is required.
