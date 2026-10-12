# Pull request: admit the current Docker server for historical reference reuse

## Summary

Allow the explicitly reviewed Engine 29.2.1 historical reference to be reused with the current Engine 29.5.2 read-only oracle while preserving every other identity and resource check. The report identifies the two versions and keeps the archived timings attributed to 29.2.1.

## Implementation

- Add a finite server-version policy: archived/current 29.2.1/29.5.2, with exact 29.2.1 unchanged admission retained.
- Keep client, plugin, kernel, OS, storage, architecture, CPU, source-log hash, Colima configuration/allocation, context and active-owner checks exact.
- Add `serverVersionTransition` to admission and acceptance records and copy both versions into each aggregate runtime-comparison row and `BENCHMARK.md`.
- Keep raw historical timings, workload count and all timing gates unchanged; no benchmark workloads are replayed.

## Validation

Focused admission tests cover the permitted pair, reversed and unsupported versions, and mismatches in the other engine identity fields. The reuse-to-summary regression verifies the recorded versions survive into `runtime-comparison.json` and `BENCHMARK.md`.

The focused Python modules pass Docker admission 7/7 and qualification 12/12 tests. Python compilation, Markdown lint under the single-line paragraph policy, and `git diff --check` pass. These are deterministic component checks; full unattended qualification and artifact publication remain required. The failed `2ac01630-config-id-20261003` reference-admission attempt remains retained with host and Colima restoration confirmed.
