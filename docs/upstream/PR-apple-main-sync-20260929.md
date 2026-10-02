# feat: synchronize container with Apple main through `d5023f40`

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Apple advanced `container` by six commits after the selected fork base. This merge brings in upstream CLI help and unknown-command behavior, guest kubeconfig sanitization, a plugin-error test correction, a test-support fixture split, and the new `container commit` command. It preserves the fork's build provenance, runtime changes, and dependency pins. Apple's two commit integration test bodies remain unchanged; the file alone is renamed to match the fork's filename-derived suite selector. The source merge does not republish the previously qualified runtime or alter historical benchmark evidence.

## Testing

- [x] Tested locally: the earlier five-commit merge passed 28 native tests and 22 focused kubeconfig tests; the new command target built and 230 ContainerCommandsTests passed without skips.
- [x] Added/updated tests: upstream tests were merged and adapted to the fork.
- [x] Added/updated docs: this PR note and its matching issue.

The earlier five-commit `make check` passed using Swift 6.3 and the repository-compatible Hawkeye 6.5.1 binary. The focused `KubeconfigMergeTests` run passed 22 tests in six suites, including four sanitization cases. A real rootfs-tar/OCI archive unit regression covered all 61 executable lines in `OCIImageArchive.swift`; the release CLI built and `container commit --help` resolved the new command. The two stopped/running upstream commit cases, fresh hosted analysis, full runtime qualification and downstream Compose qualification remain pending. Do not treat this source candidate as a released or qualified runtime.

## Compatibility and risks

The CLI still displays the fork's build provenance, and unknown commands now use Apple's clearer diagnostic. Guest kubeconfig data is reduced to the expected single cluster, user, and context before a host merge; execution-capable credentials are refused. The new commit command exports a container filesystem into an OCI image and loads it under the requested reference. Existing published product and benchmark identities retain their original source revisions.

## Related work

See [the matching issue](ISSUE-apple-main-sync-20260929.md).
