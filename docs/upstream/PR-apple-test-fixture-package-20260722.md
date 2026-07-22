# Pull request handoff: adopt Apple Container test fixture package

## Summary

Adopt Apple Container PR [#1887](https://github.com/apple/container/pull/1887)
as a minimal test-only package-layout update. The fork keeps its small,
Compose-adjacent test helpers in `ContainerTestSupport`; it does not add
fork-specific behavior to a production Container target.

## Apple-shaped boundary

- Accepts Apple’s test-fixture target and the upstream test imports unchanged
  wherever there is no fork-specific helper.
- Keeps only the existing builder-name, IPv6-gateway, and TCP-port helpers;
  they are public solely because the new target is imported by test targets.
- Restores the moved helper’s standard license header rather than creating a
  new header convention.
- Makes no change to public runtime APIs, CLI commands, network allocation, or
  Compose translation code.

## Code map

| Path | Change |
| --- | --- |
| `Package.swift` | Adds Apple’s `ContainerTestSupport` library product and exposes it to tests. |
| `Sources/ContainerTestSupport/` | Holds the moved shared fixtures and the retained fork test helpers. |
| `Sources/ContainerTestSupport/ContainerFixture+PortHelpers.swift` | Keeps the port fixture public and restores its repository-standard header. |
| `Tests/IntegrationTests/` | Imports the shared fixture module from test targets. |

## Validation

```console
make test
make check
make coverage-unit
```

Verified on Apple silicon macOS:

- The full test invocation passed 1,122 tests in 129 suites.
- Formatting and license checks passed.
- The unit coverage target passed 1,123 tests in 129 suites and generated its
  JSON, HTML, and summary reports.

Docker Compose V2 behavior is not changed because the downstream Compose pin
remains on the already-published `current` prerelease. Its current parity
evidence is intentionally retained rather than claiming a new runtime pin or
prerelease from this maintenance-only fork sync.

## PR template

### Type of change

- [x] Build/test infrastructure maintenance
- [x] Documentation update
- [ ] New feature
- [ ] Breaking change

### Motivation and context

Apple has extracted shared integration fixtures into a dedicated test package.
Keeping the fork aligned avoids duplicate fixtures while preserving the few
test-only extensions required by the existing macOS stack validation.

### Testing

- [x] Tested locally on macOS
- [x] Full repository test build passed
- [x] Unit coverage generated
- [x] Formatting and license checks passed
- [x] Documentation updated
- [ ] Docker Compose V2 parity (no downstream Compose pin change in this PR)

## Commit tracking

- `d84512020ff94ab594b45dc656a6a1d41ee3275f`
  (`merge: integrate apple container test fixture package`)
- `90f7d2cadec545bcdf262daedece0ba87aa1b214`
  (`fix(tests): restore test fixture license header`)
