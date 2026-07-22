# Upstream sync: Apple Container test fixture package

## Context

Apple commit
[`a51d54b5531751062bca9664c08ad09882716b9a`](https://github.com/apple/container/commit/a51d54b5531751062bca9664c08ad09882716b9a)
(`Container test fixture package (#1887)`) moves common integration fixtures
into the public-for-tests `ContainerTestSupport` Swift package target. The
fork carries narrowly scoped fixture extensions used by its macOS networking
and builder tests, so the move must preserve those helpers without changing
the Container CLI or runtime surface.

## Required behavior

- Adopt Apple’s `ContainerTestSupport` package layout and test-target imports.
- Retain the fork’s named builder, IPv6 gateway, and TCP-port fixture helpers
  as public test-support APIs.
- Preserve the project-standard license header when the local port-helper file
  is moved with the new target.
- Keep the change restricted to macOS test infrastructure. No Docker,
  Compose, Linux-host, or Windows behavior is introduced.

## Scope and non-goals

This is a source-layout and test-target maintenance update only. It does not
alter a production module, a command-line contract, launchd configuration, or
the downstream Compose pin. The published Compose `current` prerelease remains
on its existing seven-day stable-release soak; a new Compose V2 parity run is
therefore not applicable to this unpinned runtime-only sync.

## Reproduction and validation evidence

The initial merge was checked with the repository’s macOS-native quality and
coverage targets. The target compiles against the relocated helpers, and the
full test suite keeps the integration-test sources in its build graph.

```console
make test
make check
make coverage-unit
```

Observed results:

- `make test`: 1,122 tests in 129 suites passed.
- `make check`: Swift formatting and license-header validation passed.
- `make coverage-unit`: 1,123 tests in 129 suites passed; the generated unit
  coverage summary reported 38.50% line coverage, 40.26% function coverage,
  and 40.33% region coverage for the repository-wide instrumented target.

## Commit tracking

- `d84512020ff94ab594b45dc656a6a1d41ee3275f`
  (`merge: integrate apple container test fixture package`)
- `90f7d2cadec545bcdf262daedece0ba87aa1b214`
  (`fix(tests): restore test fixture license header`)
