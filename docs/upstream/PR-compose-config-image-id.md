# Pull request: resolve local images by config digest

## Summary

Add an async local-image lookup fallback for exact bare SHA-256 OCI config IDs. This keeps Docker image-ID semantics intact and lets Compose image checks, metadata lookup, and Container create/fetch use the same resolver.

## Implementation

- Keep the existing synchronous reference, manifest digest, prefix, and display-name resolution first.
- For an otherwise-unmatched full bare SHA-256 ID, read platform manifest descriptors and compare their config descriptor digests. Skip attestation descriptors; fail closed for unreadable candidate content.
- Deduplicate aliases by index digest, choose a deterministic alias, and report an ambiguity error when distinct indexes share the requested config ID.
- Reject a config ID found in a multi-platform index; current metadata and create APIs cannot pin the matched platform variant end-to-end.
- Re-throw cancellation and operational config-ID lookup failures from the multi-name path so Compose cannot treat unreadable images as absent.

## Tests

`ClientImageLookupTests` covers unique and missing config IDs, ambiguity, alias deduplication, cancellation and unreadable candidates, manifest/named digest precedence, and rejection of multi-platform config IDs until variant pinning is supported. The resolver scans platform descriptors and excludes attestations.

## Validation

The focused `Tools/bazel/run.sh test @swiftpkg_container//:ContainerAPIClientTests.rspm --test_filter=ClientImageLookupTests` run passes all 19 lookup tests at retained invocation `20261002T232225Z-69129`. The initial umbrella target also selected MachineAPIClientTests, whose filter matched no tests; the direct target resolves that selection error. The initial `swift test --filter ClientImageLookupTests` attempt entered full SwiftPM dependency resolution and was stopped before compilation. Failed and interrupted attempt evidence remains retained. Runtime, dependent Compose release, signing, and publication validation follow the clean source checkpoint.

## Release impact

The Container source revision and its package lock must be advanced by the owner. The enhanced Compose binary statically consumes `ContainerAPIClient`; rebuild and re-sign that dependent release asset against the fixed Container revision and refresh its release provenance and digests.
