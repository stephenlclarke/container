<!-- markdownlint-disable MD013 -->

# fix(build): expose guarded prepared runtime comparisons

## Summary

Add `bazel-runtime-comparison` to perform reference admission, fresh candidate measurements, Docker reference admission and the existing comparison gate. `Tools/bazel/unattended.py --target bazel-runtime-comparison` runs it with the original host ownership and restoration rules. `PREPARED_RUNTIME` is mandatory; `BENCHMARK_TRIALS` defaults to seven.

## Validation

All 42 unattended, runtime benchmark and integration harness regression tests passed. The new unattended target participates in the real inherited-descriptor startup regression, including startup failure, independent command locks and worker restoration. A Make dry run confirms only the four selected operations.

## Compatibility and limits

Existing targets and default qualification are unchanged. Prepared binaries retain their measured source revision, which can precede a harness-only change after exact production inputs are verified. Reused references retain their original host and binary identities; this is not a contemporaneous reference measurement or a claim of equal performance. Fresh live results are retained separately.

## Links

[Issue](ISSUE-prepared-runtime-comparison.md)
