# Synchronize Apple `container` through `d5023f40`

<!-- markdownlint-disable MD013 -->

## Context

Apple `container` advanced by six commits after the fork's selected base:

- `2e23485f` improves the unknown-command error;
- `6fba6246` places plugins with other subcommands in CLI help;
- `31a069a1` sanitizes guest kubeconfig values before merging them into the
  host configuration;
- `d265d669` updates the plugin-error integration test;
- `f7a75fb9` removes Swift Testing from the production test-support target;
- `d5023f40` adds `container commit`, a generated OCI image archive, and stopped/running container tests.

The fork's qualified runtime and Compose dependency pins remain tied to their published revisions. This sync is new source work; it does not change historical benchmark samples or claim that a newly merged runtime is qualified.

## Required behavior

Include Apple's history through `d5023f40` while preserving the fork's build provenance in CLI help, runtime changes, and dependency pins. The kubeconfig merge must reject guest-supplied execution-capable credentials and retain only the intended cluster entry. Tests must remain available after Apple's test fixture split without adding Swift Testing to a production target. The upstream commit tests must remain discoverable in the fork's filename-derived integration selection.

## Validation gate

The earlier `f7a75fb9` merge passed 28 native tests and an integration compile. The separate focused `KubeconfigMergeTests` run passed 22 tests in six suites, including four sanitization tests, and `make check` passed with Swift 6.3 and Hawkeye 6.5.1. The `d5023f40` source merge passed 230 ContainerCommandsTests with zero skips and 61/61 executable `OCIImageArchive.swift` lines covered; the release CLI built and `container commit --help` showed the new command. The two upstream stopped/running commit cases still require the owned VM integration run, followed by fresh hosted quality and full qualification of the merged source. Earlier source checkpoints' evidence does not qualify this merge or downstream Compose.

## Related work

See [the matching PR notes](PR-apple-main-sync-20260929.md).
