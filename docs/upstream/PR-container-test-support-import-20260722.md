# Pull request handoff: import the shared Container fixture in filesystem tests

## Summary

Add the missing `ContainerTestSupport` import to the filesystem integration
test after Apple’s fixture-package extraction in
[PR #1887](https://github.com/apple/container/pull/1887).

## Apple-shaped boundary

One import reconnects an existing test to Apple’s newly extracted support
module. The change contains no new fixture API, no runtime behavior, and no
Compose-specific abstraction.

## Code map

| Path | Change |
| --- | --- |
| `Tests/IntegrationTests/Run/TestCLIRunFilesystem.swift` | Imports `ContainerTestSupport` so the existing `ContainerFixture` references compile. |

## Validation

```console
make test
make check
make coverage-unit
```

- `make test` passed 1,122 tests in 129 suites.
- `make check` passed formatting and license validation.
- `make coverage-unit` passed 1,123 tests in 129 suites.

No Compose source or runtime pin changes, so no new Docker Compose V2 parity
artifact is claimed for this isolated upstream-test regression fix.

## PR template

### Type of change

- [x] Bug fix
- [x] Test coverage/buildability fix
- [x] Documentation update
- [ ] Breaking change

### Motivation and context

The test still referenced a fixture moved to a new module. Importing that
module makes the upstream migration compile consistently.

### Testing

- [x] Reproduced on macOS before the fix
- [x] Full repository test build passed after the fix
- [x] Unit coverage target passed
- [x] Formatting and license checks passed
- [x] Documentation updated
- [ ] Docker Compose V2 parity (not applicable: no Compose behavior changed)

## Commit tracking

- `195e4639d6fa66362dbaf1f731ad1f0fdeb25648`
  (`fix(tests): import shared container fixture`)
