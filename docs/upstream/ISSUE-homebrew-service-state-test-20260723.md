# Homebrew formula test depends on daemon state

## Context

The Container Homebrew formula used `container list` as a negative smoke test
and required exit status 1 with a daemon-unavailable error. That assertion
passes after a fresh formula installation, but fails when a developer follows
the documented service instructions before running `brew test`.

The `0.8.0` stable package reproduced the problem on Apple silicon macOS:

```console
brew services restart stephenlclarke/tap/container
brew test stephenlclarke/tap/container
```

The installed runtime was healthy, so `container list` correctly returned exit
status 0. Homebrew then reported `Expected: 1, Actual: 0`.

## Required behavior

- Keep the formula smoke test independent of daemon state.
- Exercise the packaged `container` executable and a real subcommand surface.
- Avoid starting, stopping, or modifying a developer's Container service.
- Retain the maintained formula template as the source for generated tap
  formulae.

## Resolution

The signed commit
[`701c1c4ef991ee3b1cb147c3a777f7d3d566d497`](https://github.com/stephenlclarke/container/commit/701c1c4ef991ee3b1cb147c3a777f7d3d566d497)
keeps the version smoke and replaces the daemon-dependent list request with
`container list --help`. The help path validates command registration and
argument parsing without contacting the API server.

A template regression test requires the service-independent help invocation
and rejects the former live-list assertion, so every generated stable or
Current formula inherits the correction.

## Validation

```console
make check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover scripts \
  -p 'test_update_homebrew_formula.py'
ruby -c Formula/container.rb
make test
make coverage-unit
container list --help
```

Observed on Apple silicon macOS:

- Formatting and license checks passed.
- Both formula updater tests passed.
- Ruby syntax validation passed.
- The normal unit target passed 1,134 tests in 131 suites, plus XCTest.
- Instrumented unit coverage passed 1,135 tests in 131 suites.
- Unit coverage remained 38.82% lines, 40.44% functions, and 40.60% regions.
- `container list --help` returned exit status 0 while the Homebrew service was
  running and displayed `List running containers`.

The Compose `0.8.0` release gate independently passed all 25 live runtime tests
and all 56 strict Docker Compose 5.3.1 parity suites before this packaging-only
test issue was found.

## Commit tracking

- Formula and regression test:
  `701c1c4ef991ee3b1cb147c3a777f7d3d566d497`.
