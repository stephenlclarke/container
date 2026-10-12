<!-- markdownlint-disable MD013 -->

# fix(build): stabilize host timeout fixtures and combine layer checks

## Implementation

Only the macOS setup in the two imported AsyncHTTPClient timeout tests changes. A local TCP listener accepts but never finishes TLS, exercising the real connection establishment deadline with the original connectTimeout and duration assertions. Linux setup and production library code are unchanged. The existing host-only admission guards remain.

`bazel-layer-check` requests the product and complete test suite together with keep-going enabled, and `bazel-check` reuses it after the tool checks. Build-only layers retain the normal build target.

## Validation

The focused connect-timeout selection passes all three selected cases, including both corrected end-to-end fixtures. The complete HTTP-client host suite passes in 60.9 seconds, with every original case retained. Only the modified test fixture was recompiled; the product reused its existing build actions. Earlier passing dependency stages are preserved. These are source build/test changes; previously released GA binaries and their notarization are unchanged, and historical artifact receipts are not relabeled under the new patch recipe.

## Compatibility and risks

The fixture measures the overall real connection establishment deadline, including TLS, rather than relying on TCP backlog saturation. Imported artifact recipes include patch bytes and remain subject to their original exact-input admission. No new stable release or broad recipe compatibility waiver is claimed.
