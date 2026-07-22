# Upstream regression: missing test-support import after fixture extraction

## Context

Apple Container PR [#1887](https://github.com/apple/container/pull/1887)
moved `ContainerFixture` into the new `ContainerTestSupport` module. The
upstream migration adds the module import to most integration sources but
omits `Tests/IntegrationTests/Run/TestCLIRunFilesystem.swift`, which still
uses `ContainerFixture`.

## Reproduction

On a macOS checkout containing the fixture-package update, run:

```console
make test
```

Before the fix, the integration-test target fails to compile because
`TestCLIRunFilesystem.swift` cannot resolve `ContainerFixture` from its old
module location. The failure is deterministic and does not require a running
guest, Docker installation, or Linux host.

## Resolution

Add the one required module import:

```swift
import ContainerTestSupport
```

The fix is test-source-only. It does not change the Container runtime, any
public production API, or the Compose layer.

## Validation

```console
make test
make check
make coverage-unit
```

The full test invocation passed 1,122 tests in 129 suites. The quality gate
passed, and the instrumented unit target passed 1,123 tests in 129 suites.

## Commit tracking

- `195e4639d6fa66362dbaf1f731ad1f0fdeb25648`
  (`fix(tests): import shared container fixture`)
