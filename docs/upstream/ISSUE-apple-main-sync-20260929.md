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

## Related work

See [the matching PR notes](PR-apple-main-sync-20260929.md).
