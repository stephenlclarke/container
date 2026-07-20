# Preserve image volume metadata through `ImageResource`

## Summary

Update the Containerization pin and test that Docker image `Volumes` metadata
travels through the existing `ImageResource` projection.

## Implementation

- Pin Containerization to the additive `ImageConfig.volumes` model change in
  [`20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e`](https://github.com/stephenlclarke/containerization/commit/20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e).
- Add Docker config fixture volume declarations to the existing image-resource
  client test.
- Assert the decoded variant retains both destinations.

## Validation

- `swift test --filter ClientImageImageResourceTests`
- Complete Container unit suite with coverage before submission.

## Compatibility

No runtime behavior changes. The existing public image config projection gains
access to metadata that was previously discarded by the dependency model.
