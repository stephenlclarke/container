# Compose cannot resolve a local image by its Docker config digest

## Motivation

The enhanced Compose runtime uses the shared Container image client to check local images and load image metadata. Docker-compatible image IDs are the SHA-256 digest of the image config, while Container's image list stores the index descriptor digest. A local image reference such as `sha256:<config-digest>` therefore appears absent to Compose even though its OCI manifest and config are present locally; a later container create follows the same lookup path and can incorrectly attempt a pull.

## Required behavior

- Resolve an exact bare `sha256:<64-hex>` config digest to one local image when a platform manifest references that config descriptor.
- Preserve existing index-digest prefixes and named `name@digest` behavior.
- Report a digest present in more than one distinct image index as ambiguous.
- Deduplicate aliases of the same index and scan platform manifests only, excluding attestation descriptors.
- Propagate unreadable-image and cancellation errors instead of claiming an unverified unique match.
- Fail closed when the matching config belongs to a multi-platform index until downstream operations can pin the matching variant.

## Non-goals

- Change Docker-visible image IDs or substitute manifest digests for config digests.
- Add registry lookup, pulling, retries, or abbreviated config-ID matching to image lookup.
- Change Compose runtime selection or Docker Engine image-inspect behavior.

## Affected boundary

The shared `ClientImage.get(names:)` and `get(reference:)` APIs serve both Compose's live image adapter and Container's `fetch`/create path. The Compose package pins this Container source, so a source change requires the dependent enhanced Compose binary to be rebuilt and released by the owning release workflow.
