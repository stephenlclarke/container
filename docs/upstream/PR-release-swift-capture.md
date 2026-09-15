# Pull request: make the release capture explicit

## Summary

- Preserve weak ownership in the machine exit callback.
- Use Swift 6.4's explicit capture assignment syntax.
- Restore the Xcode 27 release package build used by Container Compose.

## Testing

- [x] Xcode 27 release build passes with warnings treated as errors.
- [x] Focused Machine API service tests pass.
- [x] Swift formatting, Markdown, and whitespace checks pass.
- [ ] Exact-head pull-request checks and review pass.

## Compatibility impact

This clarification has no runtime behaviour or public API impact. It keeps the
fork buildable with the current release toolchain while preserving the weak
callback ownership intended by the existing code.

## Container checks

- [x] Added matching issue and pull-request handoff records.
- [x] Preserved Apple repositories as read-only upstreams.
- [x] Used a signed Conventional Commit and Conventional Commit pull-request
  title.
- [x] Declared `Release-Note: none` because this is a compiler-compatibility
  correction with no user-visible behaviour change.
- [x] Included no credentials, private-key material, passwords, personal data,
  or private registry details.

Closes [#273](https://github.com/stephenlclarke/container/issues/273).
