# fix(copy): access stopped container files without starting their workload

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The [matching issue](ISSUE-stopped-container-copy.md) describes why copy-in before the first start and copy-out after exit currently fail. Docker supports these operations while retaining the container's lifecycle state. Runtime copy handlers already support a booted guest before its workload process starts; the API needs a scoped, recoverable owner for that access and serialization against start, stop and delete.

## Implementation status

The four API copy overloads share the existing per-container lifecycle fence and reuse a running or prepared client when available. A cold stopped dedicated container boots a copy-only guest with its mounts, suppressing workload networking, published ports/sockets, SSH, host-entry processing, logging and process monitoring. Cleanup runs on success and failure, with exact-service ownership and retryable tombstones when cleanup fails. Public status, start/finish timestamps, exit code and workload events must remain unchanged. Shared-VM stopped copy remains explicitly unsupported.

## Testing

- [x] Pinned Docker created/exited copy oracle, sparse/directory/hardlink/symlink cases and state preservation; host and Colima restored.
- [x] Focused changed suites: 87 tests passed, including copy-only configuration, exact cleanup ownership, original-error preservation and the real service's shared lifecycle fence. The fence test is deterministic and does not claim end-to-end XPC concurrency coverage.
- [ ] Live proof of the four copy overloads; the CLI covers the file/directory path, and archive-stream RPC coverage remains to be established.
- [ ] Candidate CLI/runtime proof against the same oracle fixtures, retaining monotonic durations and any timing failures.
- [x] Independent source review found no new actionable issue after cleanup/log/event/latch corrections; compiler failures remain retained.
- [ ] Final source formatting and scoped Markdown checks.
- [ ] Updated user documentation after the supported behavior is qualified.

Previously published Apple and Container candidate artifacts and benchmark measurements remain reusable and must not be rebuilt or rerun. These checkboxes report only completed evidence; they do not imply full Docker copy parity or release readiness.
