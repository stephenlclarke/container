# Synchronize Apple `container` through `f7a75fb9`

<!-- markdownlint-disable MD013 -->

## Context

Apple `container` advanced by five commits after the fork's selected base:

- `2e23485f` improves the unknown-command error;
- `6fba6246` places plugins with other subcommands in CLI help;
- `31a069a1` sanitizes guest kubeconfig values before merging them into the
  host configuration;
- `d265d669` updates the plugin-error integration test;
- `f7a75fb9` removes Swift Testing from the production test-support target.

The fork's qualified runtime and Compose dependency pins remain tied to their published revisions. This sync is new source work; it does not change historical benchmark samples or claim that a newly merged runtime is qualified.

## Required behavior

Include Apple's history through `f7a75fb9` while preserving the fork's build provenance in CLI help, runtime changes, and dependency pins. The kubeconfig merge must reject guest-supplied execution-capable credentials and retain only the intended cluster entry. Tests must remain available after Apple's test fixture split without adding Swift Testing to a production target.

## Validation gate

The staged merge resolution has passed 28 native tests and an integration compile. The separate focused `KubeconfigMergeTests` run passed 22 tests in six suites, including four sanitization tests. `make check` passed with Swift 6.3 and Hawkeye 6.5.1. Guest and CLI integration, hosted checks, and downstream Compose qualification have not run for this source candidate. Record their results before updating a released dependency pin or making a qualification claim.

## Hosted coverage follow-up

PR291's exact `6aa8648` analysis in run `36633854613` completed coverage generation but failed the unchanged new-code coverage gate at 54.8% against 80%, with no new unresolved issues. The uploaded LCOV omitted maintained `ContainerTestSupport` source because of an export exclusion; Sonar correctly counted its 18 new lines as uncovered. Thirteen new PluginLoader help lines and two DefaultCommand diagnostic lines were also uncovered.

The correction includes ContainerTestSupport in coverage export and reuses two reviewed plugin-help tests that verify insertion after built-in commands, CLI-only filtering, missing-section formatting and unchanged help without CLI plugins. Existing support tests already exercise the explicit test identity. Runtime behavior and coverage thresholds are unchanged. With Swift 6.3 and the macOS 26.5 SDK, the focused instrumented run passed 29 tests in two suites. Its exported coverage covers all 18 previously missing ContainerFixture lines and all 13 PluginLoader help lines. Combining those observations with the unchanged-source hosted coverage gives a diagnostic projection of 71/73 new lines (97.26%); this is not a new Sonar result. A new exact-source hosted analysis remains required, and the two DefaultCommand diagnostic lines are still uncovered in this evidence.

## Related work

See [the matching PR notes](PR-apple-main-sync-20260929.md).
