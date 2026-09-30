<!-- markdownlint-disable MD013 -->

# build: verify published native dependency consumption

## Type of Change

- [x] Build workflow change
- [x] Documentation update

## Motivation and Context

The optimized runtime previously accepted a warm source-build cache without proving which dependency binaries reached the final products. This change adds a separate published native layer chain while preserving the existing source-mode tests and historical benchmark recipes. The producer seals configured compiler outputs and finite source-test evidence, the importer binds all three release assets and each lower layer, and the existing runtime-smoke build verifies the canonical repository overrides and complete action graph before staging and signing. Prepared reuse and release packaging recheck the retained build, action, archive and fingerprint evidence.

The four layers are now published and download-verified. Normal import supplies 37 canonical repositories, and the `db4088b1` optimized runtime smoke verified all eight links with no imported compilation or archive actions. Its later instrumented integration failed on Bazel's metadata-only `BaselineCoverage` action, so that run is not qualified. The narrow coverage admission and exact old/new importer-verifier recipe binding reuse the original four releases without altering their proofs; a new complete qualification is pending.

## Testing

- [x] Added focused producer, importer, archive-format and consumer admission tests with tamper and source-fallback rejection cases.
- [x] Replayed the verifier against the retained full-chain development action graph.
- [x] Publish and verify the four dependency layers from clean reviewed source checkpoints.
- [ ] Run the full native Container qualification and final release checks against those exact assets.

See [the matching issue](ISSUE-native-compiled-layers.md) for the required acceptance boundary.
