# Pull request handoff: make the Homebrew smoke service-independent

## Proposed pull request

`fix(homebrew): make formula smoke service-independent`

This handoff covers the signed source commit
[`701c1c4ef991ee3b1cb147c3a777f7d3d566d497`](https://github.com/stephenlclarke/container/commit/701c1c4ef991ee3b1cb147c3a777f7d3d566d497).

## Summary

Validate the packaged Container CLI with `container list --help` instead of
requiring a live list request to fail. The formula test now passes whether the
developer's Container service is stopped or already running.

## Apple-shaped boundary

- Changes only the maintained Homebrew formula template and its focused
  generator regression.
- Uses the public CLI help path; no Container API or runtime behavior changes.
- Does not stop, start, or inspect the developer's daemon from a formula test.
- Keeps formula generation, service registration, installation, and package
  layout unchanged.

## Code map

- `Formula/container.rb`
  - retains the executable version assertion;
  - validates the list subcommand through its service-independent help path.
- `scripts/test_update_homebrew_formula.py`
  - requires the help-based assertion in the maintained template;
  - rejects regeneration of the old daemon-dependent assertion.
- `docs/upstream/ISSUE-homebrew-service-state-test-20260723.md`
  - records the reproduction, behavior, and validation.
- `docs/upstream/PR-homebrew-service-state-test-20260723.md`
  - provides this upstream handoff.

## Validation on macOS

```console
make check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover scripts \
  -p 'test_update_homebrew_formula.py'
ruby -c Formula/container.rb
make test
make coverage-unit
container list --help
```

Results:

- Formula updater regressions: 2 passed.
- Container unit tests: 1,134 tests in 131 suites passed.
- Instrumented unit coverage: 1,135 tests in 131 suites passed.
- Unit coverage: 38.82% lines, 40.44% functions, 40.60% regions.
- The help smoke passed with the installed Homebrew service running.

## Compatibility and risks

The test no longer verifies the specific error returned by an unavailable API
server. That error was an environmental condition rather than a package
contract. The replacement still loads the packaged executable, resolves the
`list` command, and renders its options, while remaining deterministic in both
service states.

No executable source or release asset changes. Downstream Compose runtime and
Docker Compose parity behavior is unchanged.

## PR template

### Type of change

- [x] Homebrew packaging fix
- [x] Test reliability
- [x] Documentation update
- [ ] Runtime behavior
- [ ] Breaking change

### Motivation and context

`brew test` must not fail merely because the formula's documented service is
running and `container list` succeeds.

### Testing

- [x] Reproduced the former failure with the service running
- [x] Formula updater regression passed
- [x] Ruby syntax passed
- [x] Formatting and license checks passed
- [x] Full unit suite passed
- [x] Instrumented unit coverage passed
- [x] Help smoke passed with the service running

Related issue handoff:
`docs/upstream/ISSUE-homebrew-service-state-test-20260723.md`.
