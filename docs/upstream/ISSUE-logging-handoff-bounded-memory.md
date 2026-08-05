# Runtime gap: bounded-memory logging handoff

## Problem

The logging handoff transport had independently authenticated file-backed
frames, but native source history and destination history records still crossed
parts of the Container boundary as aggregate `Data`. A valid retained history
set could therefore require memory proportional to the complete payload even
though the object transport itself was bounded.

The same gap applies to any upstream adoption of the provider handoff feature.
It is not a Compose parser defect and cannot be closed only in the downstream
adapter.

## Required behavior

- Pin each quiesced local history inode and copy it without reopening a mutable
  path.
- Keep Docker json-file, native-local, dual-cache, and portable histories in
  private files through canonical sealing and opening.
- Preserve the deterministic CBOR schema, lineage digest, transport digest,
  source device/inode evidence, compression state, rotation order, and native
  sequence bounds exactly.
- Decode nested history bytes without reconstructing the canonical package or
  complete history set in memory.
- Validate and promote at most one bounded history segment at a time.
- Retain the v1 materializing API only for compatibility.
- Remove every private temporary file after the owning export/import operation.

## Acceptance evidence

- [x] Source copies use 64 KiB chunks from pinned descriptors into private
  mode-0600 files while hashing.
- [x] Canonical history records stream file bytes into the deterministic CBOR
  byte-string position without changing the wire schema.
- [x] Framed canonical opening returns individually file-backed records.
- [x] Destination extraction, staging, reconciliation, and immutable
  publication retain file-backed history and map one segment at a time.
- [x] Exact portable, Docker json-file, native-local, framed transaction, and
  source-to-destination regressions pass on the programme MacBook Pro with
  warnings treated as errors.

## Publication boundary

The implementation is retained locally on `upstream/logging-driver-parity`.
No Apple issue, pull request, branch publication, or push has been created.
Upstream publication remains deferred until all programme development is
complete and the matched Engine API dependency can be proposed coherently.

Related pull-request handoff:
`docs/upstream/PR-logging-handoff-bounded-memory.md`.
