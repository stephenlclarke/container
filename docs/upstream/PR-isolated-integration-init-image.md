# Pull request: load the matched init image after isolated test cleanup

## Summary

- Move `init-block` into the existing integration execution sequence, after
  the optional `APP_ROOT` cleanup.
- Remove the earlier duplicate `init-block` prerequisites from the normal and
  coverage integration paths.
- Keep the source-matched `vminit:latest` guest available to the CPU,
  namespace, and security integration assertions without a Docker Hub pull.

## Apple-shaped boundary

This is a Makefile-only test-orchestration correction in `apple/container`.
It reuses the established `init-block` and does not modify public CLI behavior,
runtime services, image resolution, or Compose code.

## Code map

- `Makefile`: clear a caller-provided test root, then invoke the existing
  `init-block`, then start the test server and run the CLI suites.

## Validation

```sh
APP_ROOT="$PWD/.test-scratch/isolated-init-image-app-root" \
LOG_ROOT="$PWD/.test-scratch/isolated-init-image-log-root" \
CONTAINERIZATION_INIT_SOURCE_PATH=/path/to/containerization \
make coverage-integration
make check
```

The clean 0.7.0 candidate stack ran the command with its pinned
Containerization `497406f` checkout and the documented local Phase 5 Builder
exception. Its concurrent partition passed 233 tests in 26 suites, including
the CPU, namespace, and security tests that explicitly select
`vminit:latest`, with no request for
`registry-1.docker.io/v2/library/vminit`. Its serial partition passed every
selected suite except the separately documented external-Dockerfile local-output
and tar-export Builder gaps. `make check` also passed. This change is test
orchestration only, so Docker Compose configuration parity does not apply; the
Compose release gate consumes the validated runtime build.

## Compatibility and risks

The image is still generated and loaded by the same `init-block`; only its
position relative to an explicitly isolated cleanup changes. Normal developer
roots retain their existing cleanup and init-image behavior.

## Commit tracking

- `2dfec65b2bf9c863b1fdcec89432e43636c9a46b`
  (`fix(integration): load matched init image after cleanup`).
