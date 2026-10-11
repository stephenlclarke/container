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
- [x] Added a maintained `ContainerClient` archive-stream integration test for never-started and previously exited containers; it checks tar payload/mode, workload-marker behavior and canonical inspect preservation. The SDK-connected runtime selection passed, including both archive cases.
- [x] Live selected file/archive regression at `de7e48d0ad03`: 39 retained XML cases passed. The CLI covers path copies; the API test covers both archive overloads. This does not substitute for the complete differential oracle.
- [ ] Candidate CLI/runtime proof against the same oracle fixtures, retaining monotonic durations and any timing failures.
- [x] Independent source review found no new actionable issue after cleanup/log/event/latch corrections; compiler failures remain retained.
- [x] Changed source formatting and scoped Markdown checks; full checkpoint gates remain pending.
- [ ] Updated user documentation after the supported behavior is qualified.

Previously published Apple and Container candidate artifacts and benchmark measurements remain reusable and must not be rebuilt or rerun. These checkboxes report only completed evidence; they do not imply full Docker copy parity or release readiness.

## File-mode regression follow-up

The first SDK-connected live proof copied the correct bytes but changed a `0640` file to `0644`. The original failure and the 30x cold-copy timing regression remain retained in `runtime-v2`; the separate file/archive integration selection passed 38 cases. The CLI now sends the source file mode through the existing API, while the SDK and guest preserve that mode independently of the ownership flag. Explicit zero permissions use the existing full `st_mode` representation so legacy raw-RPC zero still means the default `0644`. The CLI policy suite passed (13 retained XML cases), the final SDK host suite passed 68 tests, and the Linux guest mode suite passed four tests. The new live proof preserved `0640` correctly and the selected file/archive regression passed 39 retained XML cases. The complete oracle remains red: asynchronous create prewarming initialized log metadata between snapshots, and first-copy timing remained about 29x the retained Docker sample. The running and created copy fixtures cover `0640`, `0664`, executable files and overwriting an existing destination. This corrects mode handling for running copies too; workload lifecycle and data/path transfer mechanics are unchanged.

## Isolated logging proof

Default CLI creation schedules background prewarming. Its ordinary bootstrap initializes logging metadata before the workload starts, so a snapshot immediately after create can race that existing work. The maintained oracle keeps the original command order: create, inspection and log snapshot, then first copy. It records each command duration and the full create-through-first-copy duration, exposing prewarming that overlaps setup; it retains the complete before/after metadata and rejects any new or changed workload log records. Subsequent copies compare the complete log bundle. The original failed snapshot and slow timing remain immutable evidence; no new prewarm wait is inserted to make the copy appear faster. The command duration alone is not a fully cold create-to-copy benchmark.

A separate integration fixture creates containers through the existing API with explicit `prewarm: false` and `prewarm: true`. The latter waits for the existing successful bootstrap marker before its baseline snapshot. Both exercise CLI file copies and API archive copies, compare full log artifacts and inspect records, reject workload execution, and then start the actual workload to verify persistence. The corrected fixture passed both cold and fully prewarmed parameters in `runtime-v6`, including full log-artifact and inspect preservation and persistence through actual workload execution. Signed `de7e48d0ad03` runtime products and the guest were reused for that harness-only proof.

The first isolated fixture run compiled, then failed while reading `options.json` before bootstrap had written it. It now verifies the required creation options directly in the persisted `runtime-configuration.json`, which create writes before returning. That fixture failure remains retained and does not count as a runtime-copy failure.

## Standalone symlink follow-up

The completed isolated differential run in `runtime-v5` exposed default copy-out following a standalone symlink and returning a regular file. SDK `940c2034e43f4f71543149930662f9129dc36019` now keeps the final link when following is disabled, transports it through the existing archive path, and atomically installs one validated symlink from private staging. Explicit `-L` retains target-following behavior. The SDK passed 71 focused host tests and six Linux guest tests; guest helper coverage is 6/6 lines and host materialization coverage is 67/76 (88.2%), with descriptor-duplication and best-effort ownership-failure logging uncovered. The current-owner test exercises the preservation branch but does not prove transfer to a different owner. The Container regression covers relative, absolute and dangling links, target bytes/mode under `-L`, failed dangling `-L` without destination residue, and unchanged inspect/status for created, running and exited containers. At `41b74d56416f`, runtime-v7 passes all focused differential behavior operations and all 41 selected integration cases, including the three symlink state parameters and both prewarm parameters. Five cold-copy timing failures remain retained. A finite SDK-only manifest transition permits reuse of unchanged lower artifacts while source-pin checks require rebuilding the changed SDK and guest. Published baseline binaries and measurements are unchanged.

The changed native SDK artifact is published and download-verified at [layer-containerization-native-12d316a78050-6264b5793555becdb54b](https://github.com/stephenlclarke/containerization/releases/tag/layer-containerization-native-12d316a78050-6264b5793555becdb54b). Its native qualification retained 1,023 XML cases with zero failures or skips. The checked-in archive, evidence and proof locks select SDK `940c2034e43f4f71543149930662f9129dc36019`; unchanged lower native archives are reused. The matching guest built successfully and runtime-v7 passes the full focused behavior oracle and selected integration suites. Broader checkpoint gates remain pending; five cold-copy timing failures are still open.

## Offline read-only candidate

The service can read selected regular files and symlinks directly from a private bundle ext4 image while holding the same per-container lifecycle mutation slot. It excludes running/shared/custom runtimes, any runtime/prewarm client or cleanup tombstone, configured mounts, external rootfs overrides, non-private block descriptors, symlinked/hard-linked images, foreign ownership and images writable by group or other users. Images requiring journal recovery fall back to the existing guest before directory traversal. Directory transfers retain the existing guest path. Corruption or selected-path errors propagate rather than being hidden by fallback.

Blocking disk work runs off the service actor while the lifecycle slot remains held, so prewarm, start and deletion cannot mount the same disk concurrently. Regular files use bounded reads and retain existing destination-file/symlink overwrite and mode/ownership policy. Standalone links use a selected-path archive, private staging, exact-member/type validation and atomic rename. Archive transfers preserve the caller descriptor and selected basename. The SDK streams selected files, preserves sparse regions and resolves parent symlinks before `..`; final-link following remains explicit.

SDK `d428b16f5f4d2024579785779b63560926354428` passes 55 focused reader tests, including malformed superblocks/inodes, truncated symlink targets, parent-link resolution and sparse/all-hole extraction. The service helper and existing lifecycle fence pass 55 tests in three suites, including real-image bytes/modes, link handling, private-image eligibility, journal fallback and caller descriptor lifetime. Independent final source review is clear. The retained v3 service execution passed every test; a report verifier initially looked for suite names on individual cases instead of their enclosing XML suites. A corrected read-only verification accepts the same raw reports and source hashes without rerunning the tests. Live runtime and performance qualification remain pending. It has no performance claim until the changed candidate is measured against the retained Docker oracle. Copy-in still requires the copy-only guest; its two timing failures remain outstanding. The published baseline binaries and measurements are not rebuilt or rerun.
