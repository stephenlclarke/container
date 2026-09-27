<!-- markdownlint-disable MD013 -->

# fix: remove timeout polling from benchmark durations

## Problem

Python's POSIX process wait with a timeout polls for completion with sleeps up to 50 ms. The paired benchmark includes that delay in short-command timings, distorting fork/upstream comparisons.

## Expected behavior

Measure completion when the child exits while retaining a bounded timeout, nonzero status, logs and evidence. Preserve existing measurements and clearly distinguish corrected reruns.

## Acceptance

A regression rejects sleep-based exit polling. Actual child failure/output and timeout handling pass. Corrected runtime workloads pass with identical staged product fingerprints and restore the original service registrations.
