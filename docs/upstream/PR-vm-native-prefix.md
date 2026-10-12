# build(test): reuse native lower layers for SDK VM qualification

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

The repaired SDK must qualify through its real Linux VM boundary without rebuilding unchanged published native dependencies. Import the exact ArgumentParser/Foundation prefix through the maintained native verifier. Compile only the selected SDK's `cctl` and `containerization-integration` tools from source; do not import the full SDK overlay, whose payload does not include these executables.

Build, cquery and aquery share one verified override vector. A successful release BEP binds both selected unsigned binaries before stable signing. Retain source snapshot, build log, BEP, admission and complete configured action graph. Exact loaded-repository checks reject redirection; action validation rejects any non-SDK Swift package source action and requires SDK compilation plus both tool links, even when actions hit cache. Guest source must match the selected SDK lock. Retained build source snapshots must match the clean immutable source, native recipe and exact VM runner/test hashes. Staging paths reject symlinks and path escapes before use. Each run gets a fresh marker-owned home/tmp; successful cleanup removes it, while failure preserves its explicit path. Stable signing, named GPU applicability exceptions and bounded runtime remain in force.

The first immutable VM attempt compiled both tools successfully but stopped before executing tests because metadata queries selected macOS Bash 3.2 and the launcher rejected its empty options array. Retain that failure; direct metadata queries now use the enrolled Bazel binary and output root with the exact same verified flags. The build still uses the maintained launcher and retained BEP. No compiled native recipe, lower archive, baseline measurement or guest protocol changes. This fix does not make a full product or Docker parity claim.

## Testing

- [x] The new focused regression first failed because the build/admission helpers were absent.
- [x] Eight focused VM runner tests pass, including guest mismatch, SDK overlay rejection, missing/duplicate tool, lower source fallback, repository mismatch, unsuccessful build/query ambiguous output rejection, staging path redirection and unmarked state cleanup rejection.
- [x] Instrumented Python coverage reports 82/82 executable lines across the five new helpers (100%). Whole runner coverage is 154/250 (61.60%); runtime/signing/cleanup orchestration is not represented by mocked unit proof and requires the separate immutable VM gate.
- [x] Repaired SDK guest and optional-runc guest builds passed; common guest binaries match exactly and host services were restored.
- [ ] Fresh immutable VM integration execution against the repaired SDK.
- [x] README and matching issue handoff updated.

Evidence is retained in the active performance goal under `candidate-sdk-unaligned/vm-runner-red-v1`, `vm-runner-green-v1` and `guest-v1`; raw earlier failures remain visible. A first coverage invocation collected no data because it selected a file path as a module name; the corrected instrumented run is authoritative. No unchanged historical baseline was rebuilt or rerun.

Related: [issue handoff](ISSUE-vm-native-prefix.md). No Apple/grpc publication is performed.
