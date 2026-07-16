# Apple PR Handoff: preserve signal-proxy policy for `container attach`

## Summary

Add the standard `--sig-proxy` policy control to generic `container attach`.
It is deliberately a terminal-client concern: the runtime still exposes only
the durable init-process stream relay from the preceding attach slice.

## Scope

- Parse Docker-compatible boolean values for `--sig-proxy`.
- Preserve the existing default (`true`).
- When an attached process has no TTY, disable client-side forwarding of
  `SIGHUP`, `SIGINT`, `SIGQUIT`, and `SIGTERM` when the value is false.
- Keep TTY input behavior unchanged: raw terminal control bytes remain input
  bytes rather than host-generated signals.

## Non-goals

- Compose service lookup, replica selection, and `--detach-keys`.
- Guest process lifecycle changes or a new runtime route.
- Changes to `container run`, `container start`, or `container exec`.

## Validation

- Parse `container attach --sig-proxy=false <id>`.
- Confirm the default remains true.
- Confirm non-TTY attached sessions skip host signal forwarding when disabled.

## Upstream context

This is a narrow follow-up to the durable attach primitive tracked by
[apple/container#378](https://github.com/apple/container/issues/378). It
keeps Docker/Compose policy in callers while providing the generic terminal
control needed by those callers.
