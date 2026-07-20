# Reliability gap: isolated integration roots discard the matched init image

## Impact

The CLI integration target builds and loads the source-matched `vminit:latest`
guest, then clears a caller-supplied `APP_ROOT` before the tests start. The
cleanup removes the newly loaded image while retaining only kernels. CPU,
namespace, and security checks explicitly select `vminit:latest`; with the
image absent, they resolve the unqualified reference through Docker Hub and
become dependent on registry credentials and availability.

## Required Apple behavior

- Clear an isolated integration application root before loading its matched
  init image.
- Keep the image installation within the existing `init-block` abstraction.
- Preserve normal application-root cleanup semantics and avoid reusing a
  developer's persistent runtime state.

## Non-goals

- Change user-facing init-image resolution or registry authentication.
- Preserve arbitrary pre-existing images in an integration application root.
- Change Container runtime or API behavior.
