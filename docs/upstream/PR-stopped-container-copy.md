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

The first live candidate (`6f795d10436e`) reached the copy-only guest but failed the SDK's remaining started-state guard. The source fix is now pinned to SDK `c173865d20c694dfcea662a0f4b20a2d1c0005d0`: all four SDK copy overloads accept its prepared filesystem state under the existing lock. No initial workload process is created. Its 66 lifecycle tests pass, with 15/15 executable lines covered in the new state accessor; the original live failure and initial test-fixture failures remain retained. Guest rebuild inputs are affected because VminitdCore links this module.

## Testing

- [x] Pinned Docker created/exited copy oracle, sparse/directory/hardlink/symlink cases and state preservation; host and Colima restored.
- [x] Focused changed suites: 87 tests passed, including copy-only configuration, exact cleanup ownership, original-error preservation and the real service's shared lifecycle fence. The fence test is deterministic and does not claim end-to-end XPC concurrency coverage.
- [x] Added a maintained `ContainerClient` archive-stream integration test for never-started and previously exited containers; it checks tar payload/mode, workload-marker behavior and canonical inspect preservation. This test has not yet been run.
- [ ] Live proof of the four copy overloads; the CLI covers the path-based operations, while the new archive-stream integration test still needs runtime execution.
- [ ] Candidate CLI/runtime proof against the same oracle fixtures, retaining monotonic durations and any timing failures.
- [x] Independent source review found no new actionable issue after cleanup/log/event/latch corrections; compiler failures remain retained.
- [ ] Final source formatting and scoped Markdown checks.
- [ ] Updated user documentation after the supported behavior is qualified.

Previously published Apple and Container candidate artifacts and benchmark measurements remain reusable and must not be rebuilt or rerun. These checkboxes report only completed evidence; they do not imply full Docker copy parity or release readiness.

## File-mode regression follow-up

The first SDK-connected live proof copied the correct bytes but changed a `0640` file to `0644`. The original failure and the 30x cold-copy timing regression remain retained in `runtime-v2`; the separate file/archive integration selection passed 38 cases. The CLI now sends the source file mode through the existing API, while the SDK and guest preserve that mode independently of the ownership flag. Explicit zero permissions use the existing full `st_mode` representation so legacy raw-RPC zero still means the default `0644`. The CLI policy suite passed (13 retained XML cases), the final SDK host suite passed 68 tests, and the Linux guest mode suite passed four tests. The new live proof remains pending. The running and created copy fixtures cover `0640`, `0664`, executable files and overwriting an existing destination. This corrects mode handling for running copies too; workload lifecycle and data/path transfer mechanics are unchanged.
