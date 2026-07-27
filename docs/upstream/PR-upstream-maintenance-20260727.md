# Pull request: address reproduced July upstream maintenance findings

## Summary

- Compile each Docker ignore pattern once per build-context walk.
- Use the existing hashed context-entry set for archive membership checks.
- Sample independent container statistics concurrently while preserving the
  requested list order.
- Snapshot container and volume metadata under service locks, then perform
  filesystem traversal outside those locks.
- Derive volume active counts from the same volume snapshot used for totals
  and size traversal.
- Make source-backed integration runs start the default runtime before
  Containerization builds the matched init image.
- Make the serial empty-volume prune assertion establish its own global
  precondition.

## Apple-shaped boundary

The production changes remain in generic `apple/container` build, statistics,
and storage abstractions. They do not add a Compose concept, Docker-specific
schema, fork-only switch, or Windows path. The two integration corrections are
test-orchestration changes only.

Each behavior is a standalone signed commit so Apple can review or cherry-pick
it independently. This aggregate pull request exists to validate those commits
together in the supported macOS fork. Two review-driven follow-up commits keep
the original Foundation glob semantics and clean up a failed integration
bootstrap without widening either production boundary.

## Commit and code map

- `abab498f01c4f7325c7b41ec8254a186640824f2` caches compiled build
  globs in `Sources/ContainerBuild/Globber.swift`, with regression coverage in
  `Tests/ContainerBuildTests/GlobberTests.swift`.
- `41e31f7fe34e4a6a99ed9dd29512fd99a2cbc074` replaces linear context
  membership scans with the existing `Set` lookup in
  `Sources/ContainerBuild/BuildFSSync.swift`.
- `600fde28de94093fc5a067e19a29358a9adcec9e` fans out independent
  statistics samples in
  `Sources/ContainerCommands/Container/ContainerStats.swift`, with ordering
  and failure coverage in
  `Tests/ContainerCommandsTests/ContainerStatsCommandTests.swift`.
- `b15ac4aaf1ad7ce59a124c7e222a427565525d3a` moves resource-tree sizing
  outside the container and volume service locks. The implementation is in
  `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  and
  `Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift`;
  focused
  concurrency coverage is in
  `Tests/ContainerAPIServiceTests/DiskUsageConcurrencyTests.swift`.
- `345ae6d50db8480b1f85a481b15a6d8c291fe6d3` starts the runtime needed
  by Containerization's source init-image build. The change covers `Makefile`,
  `scripts/install-init.sh`, and `Tests/ScriptTests/TestInstallInit.sh`.
- `d48a962c30b873d054345cbbb5856eb616e4f2ee` isolates the serial
  empty-volume prune precondition in
  `Tests/IntegrationTests/Volumes/TestCLIVolumesSerial.swift`.
- `4436afea7c31a6a6a99e37ea7254465d333d9147` retains Foundation
  matching for the cached glob while preserving the existing Swift Regex
  validation contract. Its regression covers composed and decomposed Unicode.
- `25bfef8c7f810aed0442d7214e2e9fd38f3bd89c` stops only a runtime
  started by the init-image bootstrap when `make init` or image save fails.
  Its shell regression covers both failure stages.
- `98b3ae7db2d3dcfdcefd6e4eace5a65f850ac52e` reuses an already
  responsive bootstrap runtime instead of trying to register the same launchd
  label from a second application root. Its shell regression covers the
  pre-existing-runtime path used by the Compose parity harness.
- `c7d05f1e3396436d96090dbffc8f8196d34f3c1d` derives volume
  `activeCount` from the snapshotted volume paths, preventing a concurrent
  container attach from making `activeCount` exceed `totalCount`. The focused
  disk-usage regression covers active and unused paths while retaining an
  intentionally larger metadata total.

The upstream issue and pull-request handoffs for the four production changes
are retained in the consuming Compose repository so each proposal remains
independently constructible. The integration corrections have local handoffs
in:

- `docs/upstream/ISSUE-isolated-integration-init-image.md`
- `docs/upstream/PR-isolated-integration-init-image.md`
- `docs/upstream/ISSUE-integration-volume-prune-isolation.md`
- `docs/upstream/PR-integration-volume-prune-isolation.md`

## Validation

```sh
make coverage-unit
make coverage-integration
make test
make check
```

The corrected-head coverage-unit gate passed 1,148 tests in 134 suites at
39.16% line coverage. The changed build files reported 82.97% line coverage
for `BuildFSSync.swift` and 99.09% for
`Globber.swift`; the statistics and disk-usage concurrency helpers are also
exercised by focused unit tests.

The final local and hosted uninstrumented gates passed 1,147 tests in 134
suites, the complete init-image shell-ordering regression, formatting, and
license checks.
Review follow-up validation also passed all six glob test groups and all three
init-image shell scenarios: success, `make init` failure, and image-save
failure. The parity preflight added a fourth shell scenario for a pre-existing
runtime and proved that the bootstrap start is skipped.
The final connector follow-up passed both focused disk-usage tests and strict
Swift formatting after making active-volume counts snapshot-consistent.

The source-matched coverage integration gate built and loaded the matching
6.45 GB Containerization guest, then passed 293 tests in 31 concurrent suites
and 87 tests in 11 serial suites from an isolated application root, with zero
known or unexpected issues. Integration-only line coverage was 27.55% (10,785
of 39,149), and merged unit-plus-integration line coverage was 51.56% (20,187
of 39,149).

Docker Compose V2 parity is validated in the consuming Compose pull request
against this exact runtime revision.

## Compatibility and risks

- The glob cache preserves the same Swift regular-expression construction and
  validation, plus Foundation's established Unicode-scalar matching behavior;
  only repeated compilation is removed.
- Set membership uses the collection type already supplied by the call site.
- Statistics results are written by input index, so user-visible order does
  not become completion order; any sample failure still fails the command.
- Service locks continue to protect metadata snapshots. Only detached,
  read-only filesystem traversal occurs after the snapshot is released.
  Active-volume totals are derived from those snapshotted paths, so later
  container attachments cannot make the returned counts internally
  inconsistent.
- The integration bootstrap uses the default runtime only for the existing
  image build. The existing stop, isolated-root start, and image-load sequence
  remains authoritative for the test runtime. Failure cleanup stops the
  bootstrap only when the script started it. A responsive runtime is reused,
  avoiding a conflicting launchd registration for the same service label.
- The setup volume prune runs only inside the serialized destructive suite and
  changes no production behavior.

## Checklist

- [x] Standalone signed commits with conventional subjects.
- [x] Focused unit and shell regression tests.
- [x] Complete unit coverage gate.
- [x] Complete source-matched integration coverage gate.
- [x] Final formatting, generated-source, and unit gate.
- [ ] Docker Compose V2 5.3.1 parity on the consuming exact revision.
- [ ] Exact-head connector review and hosted checks.
