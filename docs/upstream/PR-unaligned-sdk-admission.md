# fix(deps): consume unaligned metadata SDK repair

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

The native SDK at `d428b16f5f4d2024579785779b63560926354428` still uses alignment-requiring raw loads. Compose's older dependency patch already repairs them. Select signed SDK `5b42fca0850b416d469de36b47bf5484385dabe0` in both Package.swift and Package.resolved before moving the coherent native stack into Compose.

The only manifest change replaces that SDK revision literal; the origin hash follows the exact manifest bytes. The finite recipe policy records the known old/new manifest hashes. It allows unchanged lower artifacts to retain their original producer recipe, while each group's source pins and lower-chain identity remain independently checked. The old SDK artifact therefore remains inadmissible for the repaired source. Unknown, reverse and unrelated build changes still fail closed. No build flag, SDK public API, filesystem mutation behavior or guest RPC changes here.

## Testing

- [x] The original SDK public-load reproducer traps on unaligned input.
- [x] The repaired maintained load methods pass two logical tests and all 24 parameter combinations, with 14/14 changed executable lines covered.
- [x] A new admission regression first rejects all six prior manifest transitions, then passes with the finite compatibility policy.
- [x] All 17 focused recipe-policy tests pass, including unknown/reverse transition, unrelated build drift and selected-policy integrity rejection.
- [x] All 1,035 native SDK qualification cases pass with zero failures or skips.
- [x] The repaired SDK archive, evidence and portable proof are published as one immutable GitHub release and download-verified.
- [x] Original ArgumentParser and Foundation archive locks remain unchanged; host services restored.
- [x] README and matching handoff documentation updated.

SDK focused proof is retained under the performance goal's `candidate-sdk-unaligned/recovery-v1`, including original failed controller receipts and raw instrumentation; no passing native test was rerun to repair reporting. The [repaired native SDK publication](https://github.com/stephenlclarke/containerization/releases/tag/layer-containerization-native-a903fa346899-f4bc0518b948d69f5ff0) completes host-layer qualification. Its archive SHA-256 is `f4bc0518b948d69f5ff0532dbed1b833f06c104788067ce699b869cc45cf2497`; evidence is `7b339b18fd53a126c0bec6ed8a6e216a51045e43cfed5d4e9b316625e307b3cf` and portable proof is `366bb1253c57ab77c1b78de68eb52ba4b64bbdcdb009d568cee962f59931199b`. Changed Container/Compose consumption and final parity remain pending. Overall coverage is not inferred from test counts. The prior SDK's 1,033-case qualification remains evidence for its original source only.

## Compatibility and remaining risks

Published baseline binaries and benchmark/parity measurements remain immutable. Reuse unchanged ArgumentParser, Foundation and Engine API archives; the checked-in consumer locks now select the qualified changed SDK layer. The guest payload needs fresh qualification because VminitdCore depends on Containerization, whose declared target closure includes the changed ContainerizationEXT4 source. No guest protocol changes, but an unchanged guest-input claim would be false. Compose's old unaligned-load dependency patch remains until the repaired native layer is admitted. This source change is not a full product or Docker parity claim.

Related: [issue handoff](ISSUE-unaligned-sdk-admission.md). No Apple or grpc issue, pull request, comment or branch is published by this change.
