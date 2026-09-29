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

## Related work

See [the matching issue](ISSUE-apple-main-sync-20260929.md).
