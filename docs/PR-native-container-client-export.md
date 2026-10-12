# feat(release): export the native Container client SDK

## Problem and resulting behavior

Compose needs Container client modules linked against the current qualified native dependencies. The native producer previously exposed only dependency groups. The new export-only `container-sdk` group collects Container's reached modules through the existing `container_sdk_outputs` aspect, retaining the native archive, evidence and portable-proof format.

Container's source record comes from the exact producer commit and canonical repository identity, independently of `Package.resolved`. Both production and publication planning bind the complete four-lower chain. Default runtime import groups remain unchanged, so the normal Container build does not import itself. No package pins, release locks or compilation aspect changed. The byte-bound recipe policy admits the complete four-file export-only vector through the previously authenticated pre-export recipe, preserving existing finite verifier/manifest transitions and returning the actual selected recipe identity. Partial vectors, unknown/reverse transitions and unrelated build changes fail closed.

## Supported commands

Run from a clean immutable Container checkout after the root-owned recipe transition is admitted. Each output must be a fresh absolute directory:

```sh
python3 -m Tools.bazel.artifacts.native_producer produce --group container-sdk --output /ABSOLUTE/FRESH/producer
python3 -m Tools.bazel.artifacts.native_producer qualify --group container-sdk --output /ABSOLUTE/FRESH/qualification
python3 -m Tools.bazel.artifacts.native_producer plan --receipt /ABSOLUTE/FRESH/producer/receipt.json --qualification /ABSOLUTE/FRESH/qualification/qualification.json --output /ABSOLUTE/FRESH/plan
```

These are proposed next-stage commands, not executed proof. The existing guarded runtime/host orchestration remains required when root executes native work.

## Validation

```sh
PYTHONPATH=Tools/bazel/artifacts python3 -m unittest Tools.bazel.artifacts.test_native_producer Tools.bazel.artifacts.test_native_evidence Tools.bazel.artifacts.test_native_format Tools.bazel.artifacts.test_native_layers Tools.bazel.artifacts.test_native_consumer
```

All 83 deterministic producer/format/evidence/importer/consumer tests pass. Instrumentation covers all 18 new executable statements and six new branch arcs. The 19 focused recipe-policy tests separately pass with retained coverage and the original red transition failure. The new group round-trips a sealed producer plan and portable proof; regressions reject an altered own revision, fabricated self dependency and any changed lower archive. The production selection test stops before a build and verifies the existing aspect and complete lower import. Qualification exercises retained source BEP/XML for the exact finite client targets and rejects omission of XPC proof. Existing default importer/consumer regressions remain green.

## Pending admission

This change is not a published client layer or a Compose compatibility result. Root still owns finite recipe readmission, actual native client compilation/qualification, publication and matched Compose consumer proof. Compose must admit the unchanged native graph and proof identities explicitly; native archives must not be relabeled as legacy enhanced artifacts. Historical performance baselines are not rebuilt or rerun.

## Linked local-package packaging correction

The first native client production attempt completed its build and BEP checks, then failed packaging because the local SwiftPM external repository links `.bazelrc` outside its linked view. That view also links source and test directories, which recursive metadata collection does not descend. The original failed attempt remains retained; it is not a qualified client archive.

Only `container-sdk` packaging now materializes the exact already-admitted clean producer commit with `git archive` into a private temporary source tree. Safe tar extraction rejects escaping tracked links. The authentic generated external `BUILD.bazel` replaces the archived build entry after unlinking it, preserving generated-header/test-data declarations without following an archived build symlink. Existing strict package confinement and all other group paths remain unchanged. Ignored and untracked host files never enter this tracked snapshot.

Focused offline regressions exercise linked-view rejection, tracked header/test-data retention, exact archive revision, generated build replacement, escaping links, temporary cleanup and unchanged dependency-group behavior. A fresh immutable native production attempt and root-owned finite recipe admission remain required; no native rebuild or qualification is claimed by these tests.

The packaging correction passes all 88 focused deterministic tests. Instrumented coverage executes every new helper statement and both outcomes of its group/revision branches. The production packaging call site remains unexecuted offline; the successful native build must be repackaged from a fresh immutable checkpoint before qualification can be claimed.
