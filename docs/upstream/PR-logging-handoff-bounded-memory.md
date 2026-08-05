# Pull request handoff: stream logging handoff history

## Summary

- Copy pinned Docker json-file, native-local, and dual-cache history to private
  files in 64 KiB chunks while computing the exact content digest.
- Encode each file into its deterministic canonical history record without
  aggregating the history bytes.
- Open framed packages into separate canonical record files and extract each
  nested history byte string to a private mode-0600 file.
- Carry file-backed history through staging, validation, immutable promotion,
  and publication while mapping at most one bounded segment at a time.
- Preserve v1 materializing APIs and the exact v1 canonical wire schema for
  compatibility.

## Apple-shaped boundary

This handoff contains the Container-owned portion of bounded logging transfer:
secure local storage snapshots, source export, canonical history encoding,
destination decoding, and controller promotion. It deliberately excludes
Compose parsing, Engine API implementation, devcontainer provider code, release
publication, and unrelated logging-provider behavior.

The corresponding Engine API and provider commits are dependencies, not part
of an Apple Container pull request:

- Engine API `44010b991cc5015e59ff81d2fa9917ae879d39d8` and
  `0d008475bfb711f7b295e44342b98d1535ab3f12`;
- devcontainer `b428031e4f1cc1bf2ede37a2b658962309e6e4c7`.

## Container implementation

- `8683e35e93c345fe823c94dfea396ae268cd3556` streams framed destination
  canonical records into private history files and carries them through
  staging and promotion.
- `60b5d5c1482a0f7edad03c72f4777f0d5fb6635f` streams native local-history
  snapshots and canonical source records into framed sealing.

Both commits are signed and retained on `upstream/logging-driver-parity`.

## Security and correctness

- Source inodes are already-open, regular, single-link files and are copied
  with positional reads.
- Destination and intermediate files are exclusive, no-follow, current-user
  mode-0600 files under mode-0700 operation roots.
- Deterministic CBOR lengths remain canonical; malformed, duplicate, trailing,
  oversized, digest-mismatched, or lineage-mismatched records fail closed.
- Temporary roots are owned by one export/import operation and are removed on
  success, failure, or payload-owner destruction.
- Exact history digest, byte length, compression, source device/inode,
  rotation, epoch, and maximum native sequence are revalidated before effects.

## Focused validation

All commands ran on the programme MacBook Pro with
`-Xswiftc -warnings-as-errors`:

- Engine canonical codec: 8/8.
- Engine portable logging payload: 6/6.
- Container logging payload: 7/7.
- Container staging/reconciliation: 8/8.
- Container framed control transactions: 7/7.
- Native source/file regressions: 4/4.
- Swift format and `git diff --check`: pass.

## Review checklist

- [x] No aggregate package or complete-history `Data` is required by v2.
- [x] One history segment is validated/mapped at a time.
- [x] Canonical and lineage digests are unchanged.
- [x] Source mutation cannot redirect an already pinned inode.
- [x] v1 callers retain their compatibility path.
- [x] Focused source-to-destination replay and transaction evidence passes.
- [ ] Rebase onto the final Apple upstream head before publication.
- [ ] Publish the matched Engine API proposal or replace it with an accepted
  upstream equivalent.
- [ ] Run the final programme-wide full suite and paired performance matrix.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do
not publish this handoff until all programme development is complete and the
user explicitly authorises the coordinated Apple upstream wave.

Related issue handoff:
`docs/upstream/ISSUE-logging-handoff-bounded-memory.md`.
