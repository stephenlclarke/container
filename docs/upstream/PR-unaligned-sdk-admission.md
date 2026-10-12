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
- [x] README and matching handoff documentation updated.

SDK focused proof is retained under the performance goal's `candidate-sdk-unaligned/recovery-v1`, including original failed controller receipts and raw instrumentation; no passing native test was rerun to repair reporting. Broader SDK native archive qualification, publication, changed Container/Compose consumption and final parity remain pending. Overall coverage is not inferred from test counts. The prior SDK's 1,033-case qualification remains evidence for its original source only.

## Compatibility and remaining risks

Published baseline binaries and benchmark/parity measurements remain immutable. Reuse unchanged ArgumentParser, Foundation and Engine API archives; produce and qualify only the changed SDK layer before updating consumer locks. The guest payload may be reused only after proving that its reachable inputs did not change. Compose's old unaligned-load dependency patch remains until the repaired native layer is admitted. This source change is not a full product or Docker parity claim.

Related: [issue handoff](ISSUE-unaligned-sdk-admission.md). No Apple or grpc issue, pull request, comment or branch is published by this change.
