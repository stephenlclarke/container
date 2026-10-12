# chore(deps): admit copy-transfer cleanup SDK

## Motivation and Context

Select SDK `518f92a006c94c55e21422f3cf2f93c2f039d053` in both package inputs. The finite manifest transition admits only this byte-bound SDK revision change from known earlier recipes. Source-pin and lower-chain validation still require a new SDK archive; unchanged published lower layers are reused.

## Implementation

The policy retains every earlier transition and exact producer recipe. Unknown, reversed and unrelated build changes continue to fail. The resolved file's origin hash matches the manifest bytes. Native locks are advanced only after the replacement SDK archive, evidence and portable proof have been published and download-verified.

## Validation

- Twenty deterministic recipe tests pass, including known transitions and unknown/reversed/unrelated negatives.
- Instrumented recipe coverage is 85/85 executable lines.
- SDK quality/native/guest/VM evidence is recorded below. Container client/Compose consumer qualification and the stated 90% coverage aim remain pending.

No baseline is rebuilt or rebenchmarked, and no matched-stack or performance improvement is claimed by this pin update. Related: [issue handoff](ISSUE-copy-transfer-sdk-admission.md).

## Published native SDK admission

The three native SDK locks now select immutable [release 410238159](https://github.com/stephenlclarke/containerization/releases/tag/layer-containerization-native-80a3b34ec73c-0f1277edc21411d7c5c1), targeting SDK `518f92a006c94c55e21422f3cf2f93c2f039d053` and produced from Container `80a3b34ec73c356e299dfbc8548d4cd5fea1c66b`. The archive SHA-256 is `0f1277edc21411d7c5c11780615058a5e0531b985fccb3d2fe4ba48527b45a20`, evidence is `1e1b6de20722ae7de808f1e9ad9562c94040a350e99f679ad01318baed156cf4`, and portable proof is `afaac077f7026a715f0ef6c4197c947238004a4327f29f4f5c47007730413b07`. All three were downloaded and authenticated after publication. Unchanged lower lock bytes are preserved.

Native SDK qualification passes 1,035 cases with no failures or skips. The same SDK source passes 1,088 Linux coverage cases and the full instrumented SwiftPM host VM suite (213 passed, two documented GPU skips). The latter is real runtime/coverage evidence, not a Bazel VM action-graph claim. Sonar analysis `9b13ed61-2df8-4f7f-9032-40ca121a1152` passes with zero new issues and zero unreviewed hotspots, at 81.5% new-code coverage. The earlier 70.2% failed scan remains retained.

The 90% coverage aim is not met: added copy-coordination source lines have 195/349 measured hits (55.87%). Existing SDK integration exercises URL copy routes, while file-handle archive overloads and defensive descriptor/error paths remain uncovered. This is an explicit coverage exception with a follow-up to add genuine archive-overload runtime coverage; it is not an all-path qualification claim. No production behavior or threshold was changed to obtain the passing scan. Full Container client, actual Compose import/compile and matched runtime proof remain pending.
