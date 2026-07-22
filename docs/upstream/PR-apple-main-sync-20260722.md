# Pull request handoff: synchronize Apple `container` main

## Summary

Synchronize the fork with `apple/container` `main` through `f4757afa`. The
merge preserves fork-specific provenance and Compose-facing package pins while
adopting Apple’s build, dependency, image-unpacking, CI, documentation, and
kernel-test reliability changes.

## Apple-shaped boundary

- Uses a single signed merge commit; no public command, API, launchd contract,
  or configuration schema is invented by the fork.
- Retains only fork-specific package provenance (`stephenlclarke/containerization`
  and the Builder shim metadata) needed by the Compose stack’s release and
  compatibility checks.
- Adds the missing `CLITests` SwiftPM target so the already-present log handler
  regression test is actually discovered. The test exercises both the legacy
  `LogEvent` path and the standard `swift-log` path without changing runtime
  code.
- Accepts Apple’s self-contained kernel fixture and loopback server. It avoids
  a network download while retaining the real install, extract, digest, guest
  boot, and restore paths on macOS.

## Code map

- `Package.swift` / `Package.resolved`
  - updates the Apple dependency constraints and lockfile;
  - keeps the fork’s stack provenance;
  - declares `CLITests` for executable log-handler coverage.
- `Sources/Services/ContainerImagesService/Server/SnapshotStore.swift`
  - adopts Apple’s ordered EXT4 journal mode for image unpacking.
- `Tests/IntegrationTests/System/TestCLIKernelSetSerial.swift`
  - replaces external archive dependence with a captured-kernel fixture;
  - restores the captured kernel after each test.
- `Tests/IntegrationTests/Utilities/KernelFixture.swift` and
  `LoopbackFileServer.swift`
  - provide deterministic local tar and loopback remote-tar test fixtures.
- `Tests/CLITests/LogHandlerTests.swift`
  - confirms both logging interfaces write file output.

## Validation

```sh
swift package dump-package
swift build -c debug
swift test --filter CLITests
swift test --filter TestCLIKernelSetSerial/
make test
make integration
```

Verified on this Apple-silicon Mac:

- `swift build -c debug` passed.
- `CLITests.LogHandlerTests/fileLogHandlerWritesLegacyAndSwiftLogEvents()`
  passed.
- `TestCLIKernelSetSerial` passed all four macOS integration scenarios,
  including guest boot and restoration of the installed kernel.
- `make test` passed 1,122 tests in 129 suites.
- The full `make integration` runner completed warmup, concurrent, and serial
  partitions and performed its launchd teardown. Its detached terminal did not
  retain a final exit code, so the focused kernel integration result above is
  retained as the explicit regression gate.

Docker Compose V2 behavior is not changed directly by this runtime sync. The
follow-up Compose stack pin must run its Docker Compose V2 parity suite before
the stack’s next prerelease is published.

## PR template

### Type of change

- [x] Bug fix / reliability maintenance
- [x] Documentation update
- [ ] New feature
- [ ] Breaking change

### Motivation and context

Align the macOS Container fork with current Apple maintenance while retaining
the minimal Compose-layer provenance abstraction. The kernel test no longer
depends on an external release archive, making macOS validation repeatable.

### Testing

- [x] Tested locally on macOS
- [x] Added or enabled unit-test coverage
- [x] Added macOS integration coverage
- [x] Updated documentation
- [ ] Docker Compose V2 parity (required in the downstream Compose pin slice)

## Commit tracking

- `599834f9f746799318a5987b62a93d0b0f198edf`
  (`merge: integrate apple main through f4757afa`).
