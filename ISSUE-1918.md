<!-- markdownlint-disable MD013 -->

# [Request]: Align container health monitoring with Docker probe semantics

## Feature or enhancement request details

This is a focused implementation note for [apple/container#1918](https://github.com/apple/container/issues/1918). The existing fork-backed health observer provides the configuration, probe execution, and `ContainerSnapshot.health` primitives needed by Docker Compose, but several runtime details still differ from Docker:

- The first probe runs immediately instead of waiting for the configured interval.
- An omitted `start_interval` falls back to the normal interval instead of Docker's five-second default.
- Failures remain exempt for the whole start period even after a successful probe has already made the container healthy.
- A zero interval, timeout, or retry count does not consistently select Docker's defaults.
- Health transitions update the snapshot but do not emit `health_status` events.
- `container list` and `container inspect` discard health when converting a snapshot to `ManagedContainer`.

These differences are visible to API consumers and orchestrators. In particular, Docker Compose `depends_on.condition: service_healthy`, `up --wait`, `start --wait`, `ps`, and `events` need stable health state and transitions rather than a liveness approximation.

The Apple-shaped fix should keep health scheduling in the API service, use the existing runtime process API for probes, preserve the additive `ContainerSnapshot.health` wire shape, and leave Compose policy in the Compose plugin. It should:

- wait before the first probe;
- use `start_interval` only while status is `starting` and the start period is active;
- use five seconds when `start_interval` is omitted or zero;
- use the normal interval after the first successful probe;
- count later failures after a successful probe even if the wall-clock start period has not expired;
- use Docker defaults for zero interval, timeout, and retry values;
- emit an event only when health status changes; and
- retain health in human-readable and structured container CLI output.

Docker-compatible probe output history and an on-demand `container healthcheck run` command remain separate API/CLI additions described by the broader issue. They are not required for Compose health gating.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
