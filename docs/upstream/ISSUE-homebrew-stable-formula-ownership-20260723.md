# Main packaging can replace the matched stable Homebrew runtime

## Summary

The Container prebuilt-binaries workflow writes its `main` package into
`Formula/container.rb` in `stephenlclarke/homebrew-tap`. The matched
container-compose stable promotion uses that same formula for the immutable
runtime paired with `Formula/container-compose.rb`.

A Container main build that finishes after a stable promotion can therefore
replace only the runtime half of the stable pair.

## Reproduction

1. Promote container-compose 0.8.0 and its matched runtime to the stable tap.
2. Complete a Container main prebuilt-binaries run.
3. Inspect the stable formulae in the tap.

The Compose formula remains at 0.8.0, while the Container formula points at a
mutable main-lane prerelease.

Observed tap commits:

- stable promotion: `78605395c27bff6bcf4a6a204e52a0ed5fca2a41`;
- first replacement: `c7f4710c0ae96283bf874a58f3901beecb69e5a7`;
- second replacement: `fa51afa5f6d26ecdcc44fa81ac1a1a22cced4b84`.

## Expected behavior

Container main builds should continue to publish immutable prerelease assets
without changing the shared stable formula. The matched container-compose
release workflow should remain the sole owner of the stable formula pair.

Named Container release branches may continue to publish their distinct,
non-stable formula names.

## Proposed fix

Expose the tap-promotion decision from lane selection and set it to `false`
for `main`. Gate tap authentication and all dependent mutation steps on that
decision. Add a focused regression that locks the lane ownership in place.

## Acceptance criteria

- [x] Main builds still package and publish prerelease assets.
- [x] Main builds cannot update `Formula/container.rb` in the shared tap.
- [x] Named release lanes retain their distinct formula promotion.
- [x] Workflow syntax and focused unit tests pass.
- [x] The stable formula pair is restored atomically after the workflow fix.
