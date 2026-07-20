# Pull request: bound VM-backed CLI integration concurrency

## Summary

- Change the default `PARALLEL_WIDTH` from all physical CPU cores to one.
- Keep `PARALLEL_WIDTH` overrideable for a validated environment.
- Document the default and the safe override point in `BUILDING.md`.

## Apple-shaped boundary

This is test-harness-only work in `apple/container`. It preserves generic
runtime behavior and makes no mention of Compose in product code. It is
appropriate for upstream because the existing integration target starts Apple
Virtualization-backed guests through a single local API server.

## Code map

- `Makefile`: defines a bounded default for the existing concurrent integration
  pass; its suite selection and serial pass are unchanged.
- `BUILDING.md`: documents the serial default and the `PARALLEL_WIDTH`
  override.

## Validation

```sh
make -n coverage-integration
make -n PARALLEL_WIDTH=2 coverage-integration
make coverage-unit
make check
```

The first two commands confirm that the default reaches the concurrent Swift
test invocation as width one and that an explicit override reaches it as width
two. `coverage-unit` passed 1,085 tests in 128 suites, and `make check` passed
formatting and license checks. The source-build primary CLI pass completed 233
tests in 26 suites without the previous XPC saturation failure; it retained the
three pre-existing vmnet-route quarantines. The serial non-builder partition
passed every functional test; its two empty-resource probes were rerun against
a new app root and passed together in 0.076 seconds after an earlier,
deliberately interrupted builder run had left resources behind.

The all-in-one integration target still reaches an independent Phase 5 builder
test failure involving an external Dockerfile path with `/tmp` and
`/private/tmp` canonicalization. It is not changed or masked by this slice and
is recorded for the ordered Phase 5 build work. Docker Compose parity is not
applicable here because no runtime or Compose feature changes; the matched
stack release gate exercises Compose against this runtime build.

## Compatibility and risks

The change trades an unsafe implicit throughput choice for a deterministic
default. Existing CI or developers that have capacity evidence can retain a
different width with `PARALLEL_WIDTH=N`. No stored state, public CLI flag, or
macOS runtime behavior changes.

## Commit tracking

- `container` implementation: `affc382b65b7ab14b21d1d0ae405dd5e613ee0df`
  (`test(integration): serialize VM-backed CLI tests`).
- No `containerization` change is required.
