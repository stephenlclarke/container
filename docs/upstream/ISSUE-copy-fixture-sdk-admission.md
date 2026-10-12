# SDK VM confinement fixture needs an explicit follow request

## Steps to reproduce

Run the full SDK VM suite at `5b42fca0850b416d469de36b47bf5484385dabe0`. The copy-out confinement fixture reads a default-preserved `/target` symlink as a host regular file, producing the only failure among 215 cases (212 passed, two named graphics skips).

## Problem description

The SDK corrects the fixture at `e4e39e2a197730d64a35b5d5116af6f3b3915c4b`: assert default link preservation, then explicitly follow inside the guest root into a fresh destination. Container must select that exact source and publish new SDK artifacts rather than relabel the previous qualification. Production SDK sources and unchanged lower dependencies retain their bytes.

## Expected behavior

Update both source pins and the resolved origin hash. Admit only the exact reviewed manifest transition for unchanged lower layers; SDK source/lower checks still reject the old SDK archive. Preserve raw failed VM evidence and all baseline artifacts.

## Environment

Local Apple silicon macOS, Bazel 8.8.0, qualified native lower layers and matched guest. Full failure evidence: performance goal `candidate-sdk-unaligned/vm-v4`. Related: [PR handoff](PR-copy-fixture-sdk-admission.md). No external upstream submission.
