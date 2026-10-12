# build: consume validated SDK and transport fork revisions

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

The released foundation selected stock SSL and gRPC source despite separately validated fork corrections. Select the actual corrected sources in Container's root graph so SwiftPM and Bazel consume them. See [the matching issue](ISSUE-lower-fork-selection.md).

## Implementation

Select SDK `96ef6bd6a3530723353fdda783f076fc0b35598b`, SSL `8f2f979a28610f47714d50eccfe16b435e7e04a5` and gRPC transport `44247d21352316e6ce3a39ba0f1f79ec39876c9f` by immutable revision at Stephen-owned URLs. Normal SwiftPM resolution produces those same selections without mirrors or local package overrides. Bazel reads these lock locations and revisions directly.

Resolution also advances transitive PunycodeSwift from 4.0.3 to 4.0.4. Its source and Package.swift are byte-identical between these revisions; only upstream CI, project metadata and documentation change. All other dependency selections remain unchanged, including the root's swift-crypto 3.15.1. The standalone SDK selected swift-crypto 4.5.1, so standalone SDK checks do not qualify this exact Container graph.

## Testing

Independent leaf checks passed: SSL custom-verification and NIOSSL suites; gRPC core and HTTP2 suites, retaining the existing unavailable-Vsock skip. SDK host unit/OCI checks passed with warnings-as-errors, retaining five existing credential/external-push skips. Root dependency resolution succeeded and its complete graph delta is retained under the performance goal's `upstream-audit/container-fork-selection` directory. Exact-head Container consumer checks and compiled-layer admission follow this source checkpoint; this document does not claim a released runtime or performance gain.

## Compatibility and Risks

Historical baseline archives, benchmark/parity records and frozen pairs remain unchanged. No guest image is substituted, and existing images do not become qualified by changing a source lock. The changed recipe and lower pins require fresh candidate foundation/downstream compiled proof and appropriate guest/runtime gates before publication. Existing builder-shim release selection is unchanged because its fork is already current with Apple.
