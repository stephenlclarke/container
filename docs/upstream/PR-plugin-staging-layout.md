# Pull request: align runtime plugin staging with the Makefile

## Summary

- Stage the native `container-build` binary at `libexec/container/plugins/build/bin/build` and `container-builder` at `libexec/container/plugins/builder/bin/builder`.
- Keep native product names for signing identifiers, entitlement files, coverage outputs, and release build inputs.
- Emit `container-executables-v3` fingerprints while retaining byte-exact support for historical v2 fingerprints.

## Code map

- `Tools/bazel/runtime_benchmark.py`: shared plugin path mapping, runtime installation staging, and v3 fingerprint selection.
- `Tools/bazel/runtime_integration.py`: recognize the aliased executables when cleaning up recorded CLI child processes.
- `Tools/bazel/runtime_coverage.py`: retain aliased executables using native product filenames for `llvm-cov`.
- `Tools/bazel/release_artifact.py`: retain v2 paths unchanged, validate v3 paths, and copy v3 binaries under their native product filenames for the existing package recipe.
- `Tools/bazel/test_runtime_benchmark.py`, `test_runtime_integration.py`, `test_runtime_coverage.py`, `test_measured_products.py`, and `test_release_artifact.py`: cover aliasing, compatibility, byte retention, missing-product refusal, and packaging names.

## Validation

Focused Python tests cover the install aliases, plugin child-process recognition, coverage filenames, exact-byte v2/v3 retention, refusal of a missing v3 builder, and restoration of native package filenames. Markdown lint is run with the retained candidate configuration, which disables only MD013.

Runtime qualification and release packaging are not executed by this source-only change. The next candidate qualification should stage the corrected paths and exercise the `builder` CLI command.

## Compatibility and risks

Historical v2 evidence continues to expect `container-build` and `container-builder` in their original plugin paths. New v3 evidence uses Makefile-compatible aliases for those two products and retains all bytes and modes exactly. The package recipe receives its original native filenames through the copy step.

## Linked issue and publication

See [`ISSUE-plugin-staging-layout.md`](ISSUE-plugin-staging-layout.md). This is a local Apple-shaped handoff; no Apple issue or pull request is created by this change.
