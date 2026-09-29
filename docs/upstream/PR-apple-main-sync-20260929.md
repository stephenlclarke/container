# chore: synchronize container with Apple main through `f7a75fb9`

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Apple advanced `container` by five commits after the selected fork base. This merge brings in upstream CLI help and unknown-command behavior, guest kubeconfig sanitization, a plugin-error test correction, and a test-support fixture split while preserving the fork's build provenance, runtime changes, and dependency pins. The staged resolution changes source and tests; it does not republish the previously qualified runtime or alter historical benchmark evidence.

## Testing

- [x] Tested locally: 28 native tests and 22 focused kubeconfig tests passed; the integration target compiled.
- [x] Added/updated tests: upstream tests were merged and adapted to the fork.
- [x] Added/updated docs: this PR note and its matching issue.

`make check` passed using Swift 6.3 and the repository-compatible Hawkeye 6.5.1 binary. The focused `KubeconfigMergeTests` run passed 22 tests in six suites, including four sanitization cases. Guest and CLI integration, hosted checks, and downstream Compose qualification remain pending; do not treat this source candidate as a released or qualified runtime.

## Compatibility and risks

The CLI still displays the fork's build provenance, and unknown commands now use Apple's clearer diagnostic. Guest kubeconfig data is reduced to the expected single cluster, user, and context before a host merge; execution-capable credentials are refused. Existing published product and benchmark identities retain their original source revisions.

## Hosted coverage follow-up

PR291's exact `6aa8648` analysis in run `36633854613` completed coverage generation but failed the unchanged new-code coverage gate at 54.8% against 80%, with no new unresolved issues. The uploaded LCOV omitted maintained `ContainerTestSupport` source because of an export exclusion; Sonar correctly counted its 18 new lines as uncovered. Thirteen new PluginLoader help lines and two DefaultCommand diagnostic lines were also uncovered.

The correction includes ContainerTestSupport in coverage export and reuses two reviewed plugin-help tests that verify insertion after built-in commands, CLI-only filtering, missing-section formatting and unchanged help without CLI plugins. Existing support tests already exercise the explicit test identity. Runtime behavior and coverage thresholds are unchanged. With Swift 6.3 and the macOS 26.5 SDK, the focused instrumented run passed 29 tests in two suites. Its exported coverage covers all 18 previously missing ContainerFixture lines and all 13 PluginLoader help lines. Combining those observations with the unchanged-source hosted coverage gives a diagnostic projection of 71/73 new lines (97.26%); this is not a new Sonar result. A new exact-source hosted analysis remains required, and the two DefaultCommand diagnostic lines are still uncovered in this evidence.

## Related work

See [the matching issue](ISSUE-apple-main-sync-20260929.md).
