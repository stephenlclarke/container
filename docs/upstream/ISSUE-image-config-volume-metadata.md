# Preserve image volume metadata through `ImageResource`

## Problem

The image-resource client transports its decoded `ContainerizationOCI.Image`
configuration to runtime consumers. Without a regression test covering Docker
`Volumes` metadata, an upstream model update could be accidentally discarded
at this API boundary and Compose could not identify Dockerfile `VOLUME`
declarations.

## Scope

This change updates the pinned Containerization dependency to
[`20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e`](https://github.com/stephenlclarke/containerization/commit/20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e)
and extends the existing image-resource fixture. It does not alter container
start, volume creation, or Docker copy-up behavior.

## Expected behavior

An image config containing Docker `Volumes` entries must retain the exact
destination map in `ImageResource.Variant.config.config`.

## Validation

- Run `swift test --filter ClientImageImageResourceTests`.
- Run the complete Container unit test suite with coverage before submission.

## Compatibility

The API already returns the entire decoded OCI image config. This test locks
in the additive metadata behavior without changing the public resource shape.
