# fix: consume corrected guest connection dependencies

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

Select SDK `7c76243f3e98ea38669f665e1bd1172db7e6b347` and gRPC transport `2ddb7175729b30e5a12f4c3cb14f15985b1b2b1e` in the candidate graph. Their changes retain the configured guest channel through activation and perform scoped transport cleanup before awaiting the connection runner. The SDK also preserves leak detection when parallel tests reuse a descriptor number and explains its optional directory-creation callback.

The exact old/new manifest hashes admit only the two revision-literal replacements. ArgumentParser source and settings are unchanged. Source-pin checks remain independent: an old Foundation archive fails the changed transport pin, an old SDK archive fails the changed SDK pin, and an old Engine API archive fails the changed lower archive identity. Archive, proof, payload and toolchain checks remain mandatory. Add Python to the existing local Linux test image for coverage export.

## Testing

- [x] The transport passed 542 applicable core and HTTP/2 tests, with one existing host-vsock applicability skip.
- [x] The signed SDK checkpoint passed full macOS coverage.
- [x] The same SDK checkpoint passed all 1,061 Linux tests and source-bound combined coverage; host services and Colima were restored.
- [x] SonarCloud passed for that exact SDK commit with zero new issues and zero unreviewed hotspots.
- [x] Twelve focused recipe-admission tests pass, including exact transition, unknown/reverse transition and unrelated build-drift rejection.
- [x] All 90 native artifact workflow tests pass. Independent read-only review found no remaining actionable issue after lock refresh.
- [x] Added/updated docs.

Affected native artifact production and full runtime parity are still required before this candidate is treated as qualified. Original failures and old artifact provenance remain retained. No unchanged baseline is rebuilt or rebenchmarked, no quality finding is waived, and no performance improvement is claimed.

Related: [issue handoff](ISSUE-connection-dependency-consumption.md).
