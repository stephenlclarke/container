# Reliability gap: isolated integration roots discard the matched init image

## Impact

The CLI integration target builds and loads the source-matched `vminit:latest`
guest, then clears a caller-supplied `APP_ROOT` before the tests start. The
cleanup removes the newly loaded image while retaining only kernels. CPU,
namespace, and security checks explicitly select `vminit:latest`; with the
image absent, they resolve the unqualified reference through Docker Hub and
become dependent on registry credentials and availability.

The original post-cleanup correction exposed a second ordering dependency:
`containerization` now constructs its Linux development image through
`container build`. The integration harness had already stopped the Container
system before calling `init-block`, so a revision-backed Containerization
checkout failed with `XPC connection error: Connection invalid` before the
matched init image could be saved or loaded.

A caller can also have a responsive runtime registered from an isolated
application root. Starting the default runtime again then asks launchd to
bootstrap the same service label from a different plist and fails with status
5 before the image build starts.

## Required Apple behavior

- Clear an isolated integration application root before loading its matched
  init image.
- Ensure the default build runtime is responsive before invoking
  Containerization's `make init`.
- Reuse a responsive runtime instead of registering the same launchd label
  from a second application root.
- Keep the image installation within the existing `init-block` abstraction.
- Preserve normal application-root cleanup semantics and avoid reusing a
  developer's persistent runtime state.

## Non-goals

- Change user-facing init-image resolution or registry authentication.
- Preserve arbitrary pre-existing images in an integration application root.
- Change Container runtime or API behavior.

## Commit tracking

- `2dfec65be7cc1d5ce52e48a295c38a9b3ddc8a7b` —
  `fix(integration): load matched init image after cleanup`.
- `345ae6d50db8480b1f85a481b15a6d8c291fe6d3` —
  `fix(integration): start runtime before init image build`.
- `25bfef8c7f810aed0442d7214e2e9fd38f3bd89c` —
  `fix(integration): stop failed bootstrap runtime`.
- `98b3ae7db2d3dcfdcefd6e4eace5a65f850ac52e` —
  `fix(integration): reuse active bootstrap runtime`.
