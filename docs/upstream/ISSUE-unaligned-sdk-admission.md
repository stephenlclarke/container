# The native SDK must contain the existing unaligned metadata repair

## Steps to reproduce

Decode a UInt64 from an EXT4 metadata buffer starting at byte offset one using SDK `d428b16f5f4d2024579785779b63560926354428`. The public helper traps with `load from misaligned raw pointer`. Compose's older enhanced graph already applies a dependency patch for this primitive; the current native archive does not contain it.

## Problem description

Selecting the newer native dependency graph without the repair would regress Compose's metadata handling. The source manifest and resolved graph must agree on the repaired SDK, and the old native SDK archive must not be relabelled as containing the change. Rebuilding unchanged lower archives would add cost without changing those dependencies.

## Expected behavior

Select SDK `5b42fca0850b416d469de36b47bf5484385dabe0`, produce and qualify its new native archive, and consume it through authenticated archive/evidence/proof locks. Reuse the unchanged ArgumentParser and Foundation archive identities. Engine API retains the same source pins and lower chain. All toolchain, source-pin, lower-chain, payload and proof checks remain mandatory.

## Environment and evidence

Local Apple silicon Mac, Swift 6.4 and Bazel 8.8.0. The SDK repair has two passing logical tests with 24 parameter combinations and 14/14 changed executable lines covered. This Container change passes 17 focused recipe-policy tests; the [native host-layer publication](https://github.com/stephenlclarke/containerization/releases/tag/layer-containerization-native-a903fa346899-f4bc0518b948d69f5ff0) now passes 1,035 qualification cases, with guest and matched Container/Compose qualification still pending. See the [implementation handoff](PR-unaligned-sdk-admission.md). No unchanged baseline is rebuilt or rebenchmarked and no upstream submission is made.
