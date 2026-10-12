<!-- markdownlint-disable MD013 -->

# fix(test): consume registry metadata through the SDK public API

## Motivation and implementation

RegistryResourceTests cannot compile against the released ContainerizationOS module. Pin the SDK public RegistryInfo initializer, replace its @testable dependency import with an ordinary import, and admit only the exact manifest transition for unchanged lower artifacts. The SDK archive must be rebuilt and independently qualified because its source pin changes.

## Validation

Add positive, unknown-recipe, reversed-transition and unrelated-file-drift checks for recipe admission. Existing mapping tests exercise the actual public initializer against the imported release. The source SDK f98a11c passes fresh native qualification and SonarCloud quality analysis with zero new issues; its three published artifacts are download-verified. All 363 maintained workflow tests pass. Upper-layer release-consumer checks remain pending; previous failures and benchmark records are retained.

## Compatibility and risks

The production API addition preserves the metadata fields and Keychain behavior. Container runtime semantics are unchanged. No testing-enabled SDK release, fabricated fixture, skipped test or baseline regeneration is used.

## Linked work

See ISSUE-registry-release-boundary.md and the SDK's docs/PR-registry-public-construction.md. The existing SDK PR 106 receives the additive public API change; Apple submission remains deferred.
