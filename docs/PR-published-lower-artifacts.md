<!-- markdownlint-disable MD013 -->

# fix(build): consume qualified lower release assets

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

The unattended Container stages previously built or reused local guest and builder OCI archives, so a successful local cache did not establish consumption of the released dependency bytes. The normal guest, runc-guest and builder stages now use the existing audited release transport and fail closed when their pinned archive or qualification sidecar is absent or incompatible. Direct runtime preparation uses the same importer when no receipt was supplied. The explicit source-build helpers remain producer commands for new dependency revisions.

The importer preserves the established `guest-artifact.json` and `builder-artifact.json` schemas for runtime, VM and release consumers. It verifies exact repository/tag/commit/asset IDs and hashes, the full OCI closure and reference, guest executable bytes, and the builder's four original test outputs. The builder supplemental release contains byte-identical pre-existing archive bytes, a path-free sidecar anchored to the accepted Q6fe public provenance, and those four original output files; it does not claim a new builder build or benchmark.

## Testing

- [x] Tested locally: the maintained tools target passed 213 tests; a real published builder import verified its archive, sidecar, Q6fe anchor and all four original test hashes.
- [x] Added/updated tests: source/lock/hash/asset-ID/runc/sidecar rejections, real OCI reference and truncation checks, and full-stage routing.
- [x] Added/updated docs: this PR and [the issue](ISSUE-published-lower-artifacts.md), the primary README and the Bazel guide.

The 33a guest and runc-guest archives passed read-only source and executable checks but remain unpublished while exact-head quality and focused VM acceptance are pending. Their locks are deliberately absent, so this intermediate checkpoint cannot complete full Q qualification. New Q source pins, current integration/coverage/hosted gates and candidate benchmarks remain separate required steps. No old version is rebuilt or rerun, and no speedup is claimed.
