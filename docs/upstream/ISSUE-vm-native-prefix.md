# VM integration rebuilds unchanged native dependencies

## Steps to reproduce

Select the repaired SDK `5b42fca0850b416d469de36b47bf5484385dabe0` and its native release, then inspect `Tools/bazel/vm_integration.py`. Its previous build and cquery invocations compile SDK test tools without published lower repository overrides.

## Problem description

VM qualification needs current SDK source tools, but unchanged ArgumentParser and foundation packages already have qualified immutable native artifacts. Rebuilding those packages wastes local resources and prevents the VM gate from proving the same layered dependency closure. Importing the entire SDK archive would also be wrong: the archive exports SDK libraries, not these two integration executables.

Use the exact native ArgumentParser/Foundation prefix, keep the SDK source-built, bind selected outputs to successful release BEP, and reject source fallback in the complete configured action graph. Guest source and the selected SDK lock must match.

## Environment

- Apple silicon macOS, the enrolled local MBP and external SSD.
- Pinned Bazel 8.8.0; existing native artifact toolchain checks remain authoritative.
- SDK repair and native publication are already qualified; VM execution remains pending.

No external issue is submitted by this handoff. Related: [PR handoff](PR-vm-native-prefix.md).
