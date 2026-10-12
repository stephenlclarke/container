# chore(deps): admit copy-transfer cleanup SDK

## Motivation and Context

Select SDK `518f92a006c94c55e21422f3cf2f93c2f039d053` in both package inputs. The finite manifest transition admits only this byte-bound SDK revision change from known earlier recipes. Source-pin and lower-chain validation still require a new SDK archive; unchanged published lower layers are reused.

## Implementation

The policy retains every earlier transition and exact producer recipe. Unknown, reversed and unrelated build changes continue to fail. The resolved file's origin hash matches the manifest bytes. Native locks are advanced only after the replacement SDK archive, evidence and portable proof have been published and download-verified.

## Validation

- Twenty deterministic recipe tests pass, including known transitions and unknown/reversed/unrelated negatives.
- Instrumented recipe coverage is 85/85 executable lines.
- Fresh SDK quality/native/guest/VM qualification and downstream client publication remain pending at this source commit.

No baseline is rebuilt or rebenchmarked, and no matched-stack or performance improvement is claimed by this pin update. Related: [issue handoff](ISSUE-copy-transfer-sdk-admission.md).
