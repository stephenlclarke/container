# Upstream sync: Apple `main` through `f4757afa`

## Context

The fork was eight Apple commits behind `apple/container` `main`. The missing
changes cover build configuration propagation for `protoc`, dependency and CI
maintenance, a source-matched EXT4 unpacker API, ordered-journal image
unpacking, documentation wording, and reliability coverage for serial kernel
tests. Keeping the fork current is necessary for the Compose stack to validate
against the same macOS Container surfaces that Apple is actively maintaining.

## Required behavior

- Integrate Apple `main` through `f4757afa` without changing public CLI or
  runtime behavior beyond the upstream changes.
- Retain the fork's explicitly configured Containerization and Builder shim
  provenance, which Compose consumes for stack consistency and release
  metadata.
- Keep all validation macOS-native: SwiftPM unit tests and Container CLI
  integration tests only.
- Preserve the existing Phase 2 release soak boundary; do not use this
  maintenance sync to begin Phase 3 volume work.

## Scope and non-goals

This is a narrowly scoped upstream synchronization. It deliberately does not
merge `apple/containerization`'s later tmpfs pod-volume change because that is
Phase 3 work and the current Phase 2 stable release is still in its seven-day
soak window.

## Apple upstream inputs

- `f4757afa` Pass build config in when building protoc dependencies.
- `0c0d3c6` CI maintenance.
- `ec44812` DNS documentation wording.
- `b130bab` Use ordered journal mode when unpacking images.
- `a6813ed` dependency maintenance.
- `06127de` Containerization EXT4 API alignment.
- `90be187` editor ignore rule.
- `1e6f782` make the serial kernel test self-contained.

## Reproduction and validation evidence

The inherited kernel test is run only on macOS and now packages the installed
kernel into a local fixture instead of downloading a release archive. It
exercises local tar, loopback remote tar, local binary, digest validation,
guest boot, and restoration of the original kernel.

The first full unit invocation ended in an unconfirmed NIO `EBADF` test-runner
signal. The suspected XPC and attach-I/O suites passed alone and in ten
parallel combined repetitions; a complete rerun passed 1,122 tests in 129
suites. No runtime change is justified without a repeatable failure.

## Commit tracking

- `599834f9f746799318a5987b62a93d0b0f198edf`
  (`merge: integrate apple main through f4757afa`).
