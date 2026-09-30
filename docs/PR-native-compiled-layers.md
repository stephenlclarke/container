<!-- markdownlint-disable MD013 -->

# build: verify published native dependency consumption

## Type of Change

- [x] Build workflow change
- [x] Documentation update

## Motivation and Context

The optimized runtime previously accepted a warm source-build cache without proving which dependency binaries reached the final products. This change adds a separate published native layer chain while preserving the existing source-mode tests and historical benchmark recipes. The producer seals configured compiler outputs and finite source-test evidence, the importer binds all three release assets and each lower layer, and the existing runtime-smoke build verifies the canonical repository overrides and complete action graph before staging and signing. Prepared reuse and release packaging recheck the retained build, action, archive and fingerprint evidence.

The development overlay build demonstrated eight links, 37 imported repositories and no dependency compilation or archive actions. It is not a substitute for published assets or full Container qualification.

## Testing

- [x] Added focused producer, importer, archive-format and consumer admission tests with tamper and source-fallback rejection cases.
- [x] Replayed the verifier against the retained full-chain development action graph.
- [ ] Publish and verify the four dependency layers from a clean reviewed source checkpoint.
- [ ] Run the full native Container qualification and final release checks against those exact assets.

See [the matching issue](ISSUE-native-compiled-layers.md) for the required acceptance boundary.
