# Issue 283: materialize missing debug symbol bundles

## Problem

The Container `dsym` target assumed SwiftPM emitted sidecar `.dSYM` bundles.
An isolated Xcode 27 and Swift 6.4 debug build instead leaves valid DWARF data
in the executables without creating those sidecars. The Container build itself
passes, but release packaging fails on the first unconditional copy.

The retained Container executable from the blocked Compose stable-release
transaction was checked with `dwarfdump`. Apple `dsymutil` materialized a
bundle with the same arm64 UUID, confirming that the release can recover the
symbols from the stock build output without changing runtime behaviour.

## Scope

- Reuse a sidecar bundle when SwiftPM emits one.
- Materialize a missing bundle with the active Xcode `dsymutil`.
- Verify exact executable and bundle UUID equality.
- Include all eight Swift executables shipped in the installer and Homebrew
  archive, including `machine-apiserver` and `k8s`.
- Stage and validate every bundle before replacing published artifacts.
- Exercise existing, missing, malformed, mismatched, and failed inputs with
  deterministic focused tests.

## Compatibility

This is a build-artifact repair that works with the stock Apple Container
source layout and the enhanced fork. It does not require a Compose-specific
runtime or protocol change.

Related issue: [#283](https://github.com/stephenlclarke/container/issues/283).
