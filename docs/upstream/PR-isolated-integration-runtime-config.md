# Pull request handoff: isolate CLI integration configuration

## Summary

Run CLI integration tests with a test-owned `XDG_CONFIG_HOME`. Before starting
the API server, remove only that test configuration's `container/config.toml`
and export the same directory to the test processes.

## Apple-shaped boundary

This is a `Makefile` test-orchestration change only. It does not change the
runtime configuration format, default configuration, CLI behaviour, launchd
service, or Compose. It reuses the existing `INTEGRATION_CONFIG_HOME`,
`APP_ROOT`, `LOG_ROOT`, and `SCRATCH_ROOT` override model.

## Problem and rationale

`container system start` snapshots the user XDG configuration into the
application root. A developer's `~/.config/container/config.toml` can therefore
silently replace the Builder image or other runtime defaults in an otherwise
isolated integration run. That makes validation depend on the workstation and
can hide a source/image compatibility failure.

Using `$(SCRATCH_ROOT)/xdg-config` by default gives every invocation a
test-owned configuration home. Removing the one generated `config.toml` before
start preserves a caller's scratch layout while preventing a previous test run
from leaking configuration into the next one.

## Code map

- `Makefile`
  - declares `INTEGRATION_CONFIG_HOME` beneath `SCRATCH_ROOT`;
  - clears the test-local configuration before each integration start;
  - exports that configuration home to both `container system start` and the
    Swift integration suites.

## Validation

```sh
APP_ROOT=/private/tmp/container-build-isolation/app \
LOG_ROOT=/private/tmp/container-build-isolation/logs \
SCRATCH_ROOT=/private/tmp/container-build-isolation/scratch \
WARMUP_FILTER=ImageWarmup/ \
CONCURRENT_FILTER=ImageWarmup/ \
SERIAL_FILTER=TestCLIBuilderSerial/ \
make integration
make test
make check
```

The local run passed all 45 Builder serial integration tests with a clean XDG
configuration, 1,087 unit tests, and `make check`. The Builder test suite
includes build contexts with Dockerfiles outside the context, which is the
workstation-dependent failure this isolation exposes reliably.

Docker Compose V2 configuration semantics are not affected: this target
validates Container's CLI runtime and leaves Compose's build normalisation
unchanged. The paired Compose release gate consumes the validated Container
package for its Docker Compose V2 build-context parity scenario.

## Commit tracking

- `9131a487492c9bbde3677a4bebe6cda69d2252b3`
  (`test(integration): isolate runtime configuration`).
