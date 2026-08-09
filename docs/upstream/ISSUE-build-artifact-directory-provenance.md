# Packaging defect: release staging can select a stale SwiftPM product directory

## Impact

`Makefile` derived `BUILD_BIN_DIR` from a new default SwiftPM invocation even
when the caller supplied `SWIFT_BUILD` with an isolated scratch path. A release
package could therefore stage products from `.build` rather than the exact
source/dependency graph that produced the requested candidate. This defeats
the package provenance boundary and can silently validate stale binaries.

The defect is present in the current Apple-shaped `origin/main` Makefile: its
default `swift build --show-bin-path` does not inherit a caller's
`--scratch-path` or other `SWIFT_BUILD` arguments.

## Required behavior

- Derive the staging binary directory with the configured `SWIFT_BUILD`
  command.
- Retain existing defaults when no override is supplied.
- Regress a dry-run package staging invocation with an injected selected build
  directory.

## Non-goals

- Change package contents, signing identities, or release publication.
- Change the normal SwiftPM build configuration.
- Add a Compose-specific packaging convention to Container.

## Local implementation

Signed local commit `c7b4898d4befad75480856305294001bd2eabf37`
(`fix(packaging): stage selected Swift build graph`) changes only the staging
lookup and adds `Tests/ScriptTests/TestBuildArtifactDirectory.sh`. The test
uses `make -n` with a controlled `SWIFT_BUILD` value and requires the emitted
`container-apiserver` install command to use that exact directory.

## Publication state

This is an Apple-shaped local issue handoff on
`upstream/logging-driver-parity`. Do not create an Apple issue or submit a pull
request until the complete Container-family programme is ready and the user
explicitly authorises the coordinated upstream publication wave.
