# Allow fresh all-component fork measurements with retained Apple baselines

## Context

The authenticated component benchmark can reuse the published stock measurements and freshly measure fork components whose source revisions changed. That is efficient for routine qualification, but it does not provide a current candidate measurement for unchanged forks when an operator explicitly requests a full all-five comparison.

## Required behavior

Add an opt-in mode that measures fresh fork candidates for all five components while retaining the published stock measurements as historical baselines. Keep the existing source, workload, lockfile, toolchain, host and benchmark-recipe admission checks. The mode must prepare and execute only fork lanes, keep old stock and fork results identified as historical, and record the full candidate inventory and selection mode in provenance. Builder and TLS workloads must honor the same candidate-only lane selection.

## Validation gate

Focused unit tests must prove all five fork lanes are prepared and dispatched, no stock lane is executed, all five retained stock baselines remain marked historical, and the mode rejects use without reference reuse. No benchmark, build or runtime workload is part of this code change's validation.

## Related work

See the matching [PR notes](PR-all-component-candidate-benchmark-20261008.md).
