# Pull request: load the matched init image after isolated test cleanup

## Summary

- Move `init-block` into the existing integration execution sequence, after
  the optional `APP_ROOT` cleanup.
- Start the default build runtime before a source-backed Containerization
  checkout invokes `container build` as part of `make init`.
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
- `scripts/install-init.sh`: ensure the default runtime is responsive before
  building the init image, then retain the existing stop, target-root start,
  and image-load sequence.
- `Tests/ScriptTests/TestInstallInit.sh`: use injected CLI, Swift, and Make
  executables to prove start-before-build, the complete handoff order, and
  cleanup after both build and image-save failures.

## Validation

```sh
APP_ROOT="$PWD/.test-scratch/isolated-init-image-app-root" \
LOG_ROOT="$PWD/.test-scratch/isolated-init-image-log-root" \
CONTAINERIZATION_INIT_SOURCE_PATH=/path/to/containerization \
make coverage-integration
make test-install-init
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

The 27 July maintenance rerun reproduced the stopped-runtime failure before
`make init`. The shell regression now proves the exact bootstrap-start, build,
save, stop, target-start, and load ordering. The source-matched coverage
integration rerun built and loaded the 6.45 GB Containerization guest, then
passed 293 tests in 31 concurrent suites and 87 tests in 11 serial suites. The
corrected-head rerun reported zero known or unexpected issues.
Integration-only line coverage was 27.55%, and the merged
unit-plus-integration line coverage was 51.56%.

The exact-head connector review then identified that the new bootstrap start
needed failure cleanup. The follow-up shell cases force both `make init` and
`cctl images save` to fail and prove that a runtime started by the script is
stopped before exit.

## Compatibility and risks

The image is still generated and loaded by the same `init-block`; only its
position relative to an explicitly isolated cleanup changes. The bootstrap
start uses the default runtime only for the image build; the existing stop and
target-root restart still select the requested isolated root before loading.
Normal developer roots retain their existing cleanup and init-image behavior.

## Commit tracking

- `2dfec65b2bf9c863b1fdcec89432e43636c9a46b`
  (`fix(integration): load matched init image after cleanup`).
- `345ae6d50db8480b1f85a481b15a6d8c291fe6d3`
  (`fix(integration): start runtime before init image build`).
- `25bfef82e76105a3c01327d702e89de1380669b1`
  (`fix(integration): stop failed bootstrap runtime`).
