# fix(deps): select corrected SDK confinement fixture

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

Select SDK `e4e39e2a197730d64a35b5d5116af6f3b3915c4b` in Package.swift and Package.resolved. The SDK fixture checks default symlink preservation separately from explicit rootfs-confined target following, correcting the retained full-VM failure without changing production transfer behavior.

The recipe policy admits only the exact new manifest hash from seven known older manifest hashes. Each group's source pins and lower-chain identities remain independently checked: unchanged ArgumentParser, Foundation and Engine API artifacts remain reusable, while the changed SDK revision requires its own archive and guest provenance. Unknown/reverse transitions or unrelated build changes fail closed. No build flags, public API, guest protocol or acceptance thresholds change.

## Testing

- [x] New regression rejects the seven transitions before the finite policy update.
- [x] All 18 focused recipe-policy tests pass with instrumented coverage retained.
- [x] SDK fixture final review is clear; Swift format and Markdown lint pass.
- [x] New SDK native qualification: 1,035 cases, zero failures/skips; immutable publication and three download-verified assets.
- [ ] New matched guest, focused fixture VM proof and complete SDK VM checkpoint.
- [ ] Container and Compose consumer qualification.

The previous SDK's 1,035 passing native cases and failed VM attempt retain their original source identity. No unchanged published baseline is rebuilt or benchmarked. The checked-in locks now select [release 410176684](https://github.com/stephenlclarke/containerization/releases/tag/layer-containerization-native-8f458f14e312-9f9ec16a8d7c62e88489). Its archive SHA-256 is `9f9ec16a8d7c62e884898f9c3323f6915c6405598357ac6bd4f8f32b84bee93c`, evidence is `7dcf0445f0a9c4eef03c4d36c1c4ed63dd59d33dfb9704ae300fc3479ce87bf1`, and portable proof is `d0c3e547d6b4b0b008d6285246918411bfc497f9870539fb55fa9ed781ce5d64`. ArgumentParser, Foundation and Engine API locks remain unchanged. Matched-stack qualification is pending; this makes no product qualification claim.

Related: [issue handoff](ISSUE-copy-fixture-sdk-admission.md). No Apple or grpc issue, pull request, comment or branch is published.
