<!-- markdownlint-disable MD013 -->

# Runtime gap: Docker GELF TCP rejected-start lifecycle

## Problem

Docker Engine accepts creation of a container whose `gelf` TCP endpoint is unavailable, rejects `docker start`, and retains a Docker-visible `created` state: zero start and finish timestamps, the GELF initialization diagnostic, and exit code `128`. Container retained the rejected-start diagnostic independently of the native lifecycle, but its Docker response projection fell back to exit code `0` whenever no native init process had run. The defect survived an authority restart because the durable error was correctly reloaded while the response projection still used the native no-process fallback.

The same failure path initially also collapsed NIO's connection-refused error into a generic logging-operation message. That hid Docker's stable `failed to initialize logging driver: gelf: cannot connect to GELF endpoint:` prefix and the configured `host.docker.internal:PORT` endpoint.

## Required behavior

- Keep a rejected eager GELF connection as a Docker `created` container; do not manufacture native start or finish timestamps.
- Preserve the configured GELF endpoint and Docker-shaped initialization diagnostic through the public start response and `State.Error`.
- Project Docker exit code `128` when a durable rejected Docker start has no native process exit code.
- Preserve normal native process exit codes and the zero exit code for a never-started container with no rejected-start error.
- Retain the error and exit-code projection after an authority restart.

## Acceptance evidence

- [x] `GELFTransportLoopbackTests.productionTCPConnectionFailurePreservesConfiguredEndpoint` preserves the configured TCP endpoint through the production provider connection failure.
- [x] `ContainerLoggingAuthorityIntegrationTests.dockerRejectedStartErrorIsInspectableAfterAuthorityRestart` verifies `created`, exit `128`, zero timestamps, and the retained diagnostic before and after authority reconstruction.
- [x] Docker Engine 29.2.1 / Docker CLI 29.7.1 references capture the initially unavailable endpoint and zero-reconnect retry-exhaustion semantics.
- [x] A fresh code-signed archive from `5e46d527391fa0830cf553c95e4be5019b82d551` passes both public Docker CLI scenarios twice under one exact fingerprint.
- [x] The candidate timings, cleanup proof, and remaining comparable-or-better performance gap are recorded in the gap-only ledger.

## Local evidence

The implementation is split into signed Container commits `73cea53bbfa3a8711a1e9320c330e4dd7c2870fa` (typed GELF connection diagnostic) and `5e46d527391fa0830cf553c95e4be5019b82d551` (Docker exit-128 projection). The focused logs and complete signed-artifact fingerprint are retained under `/private/tmp/container-gelf-tcp-failure-candidate-v6.bF5VQ7`.

Docker's unavailable reference took `0.072112500s`; two exact candidates took `0.505147750s` and `0.460362292s` (7.00x and 6.38x). Docker's zero-budget retry-exhaustion reference took `12.445434875s`; candidates took `13.568986042s` and `13.622602750s` (both 1.09x). All runs meet the fixture's 10x functional guard; the programme-wide comparable-or-better performance requirement remains open.

The Stephen-owned tracking issue [stephenlclarke/container#77](https://github.com/stephenlclarke/container/issues/77) is closed only after this exact evidence checkpoint. It remains separate from the Apple-shaped handoff.

## Apple-shaped boundary

The implementation is retained locally on `upstream/logging-driver-parity`. No Apple issue, pull request, branch publication, or push has been created. Do not publish it until all parity development waves are complete and the user explicitly authorises coordinated upstream publication.

Related pull-request handoff: `docs/upstream/PR-gelf-tcp-start-failure-lifecycle.md`.

<!-- markdownlint-enable MD013 -->
