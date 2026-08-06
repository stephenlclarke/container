<!-- markdownlint-disable MD013 -->

# Pull request handoff: preserve Docker GELF TCP start-failure diagnostics and exit state

## Summary

- Preserve a typed TCP GELF connection failure through the Docker logging backend so the public response names the configured endpoint.
- Project a retained rejected Docker start as exit code `128` while keeping the container `created` with zero lifecycle timestamps.
- Verify both the provider diagnostic and durable authority-restart projection with focused regressions.
- Certify the same behavior through two independent public Docker CLI unavailable-endpoint and retry-exhaustion runs.

## Scope

This is a narrow Docker Engine logging compatibility fix in Container. It does not change GELF configuration parsing, retry policy, Docker API route selection, Compose option projection, native process lifecycle, guest images, or any other logging driver.

## Implementation

`NIOGELFTransportFactory` now maps non-timeout TCP connection errors to `GELFProviderError.connectionFailed`, retaining the original configured network address and NIO reason. `ContainerDockerLoggingBackend` maps that typed error to Docker's stable logging-driver initialization diagnostic instead of the generic operation failure.

The native container was never started in this case, so writing a native lifecycle record would falsely change `State.Status`, `StartedAt`, and `FinishedAt`. Instead, `ContainerDockerSharedResponseBackend` keeps the durable rejected-start error as the Docker-specific state signal and projects `128` only when the native snapshot has no real exit code. A successful native start clears that durable error as before.

## Docker oracle and validation

Pinned reference: Docker Engine 29.2.1 / API 1.53 with Docker CLI 29.7.1 on the programme MBP.

- `GELFTransportLoopbackTests.productionTCPConnectionFailurePreservesConfiguredEndpoint` passes with local Containerization `38d9c695` and Engine API `4949e743`; its retained log is `/private/tmp/container-gelf-tcp-failure-candidate-v6.bF5VQ7/focused-gelf-diagnostic-regression.log`.
- `ContainerLoggingAuthorityIntegrationTests.dockerRejectedStartErrorIsInspectableAfterAuthorityRestart` passes with the same graph; its retained log is `/private/tmp/container-gelf-tcp-failure-candidate-v6.bF5VQ7/focused-start-error-regression.log`.
- `git diff --check` passes at the signed source checkpoint.
- The marker-protected root `/private/tmp/container-gelf-tcp-failure-candidate-v6.bF5VQ7` binds source `5e46d527391fa0830cf553c95e4be5019b82d551`, local Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, Engine API `4949e743675f00ec102f7acacdb4e990409e383f`, workspace state, code-signed archive, guest images, harness, wrapper, Docker references, and four candidate result/log pairs.
- Docker's unavailable-endpoint reference took `0.072112500s`; candidates took `0.505147750s` and `0.460362292s` (7.00x and 6.38x). Docker's retry-exhaustion reference took `12.445434875s`; candidates took `13.568986042s` and `13.622602750s` (1.09x). All are below the 10x focused functional guard; release-wide comparable-or-better performance remains a distinct gap.

## Review checklist

- [x] A failed eager GELF connection preserves its configured endpoint and Docker-shaped diagnostic.
- [x] Rejected starts retain `created`, zero timestamps, and exit code `128` across authority restart.
- [x] Real native process exit codes continue to take precedence over the Docker rejected-start fallback.
- [x] A fresh signed candidate passes both public Docker CLI failure scenarios twice and cleans up its exact socket and runtime processes.
- [x] The exact evidence, timing comparison, and gap-only ledger updates are retained.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all parity development waves are complete and the user explicitly authorises the coordinated Apple upstream wave.

Related issue handoff: `docs/upstream/ISSUE-gelf-tcp-start-failure-lifecycle.md`.

<!-- markdownlint-enable MD013 -->
