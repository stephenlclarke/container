# Compatibility gap: persisted container stop defaults

## Surface

Generic `container run/create --stop-signal` and `--stop-timeout`, and an
unspecified later `container stop` operation.

## Problem

Images may provide a stop signal, but a client could not configure a generic
per-container stop signal or grace timeout at creation time. In addition,
`container stop` always supplied a five-second timeout, so there was no way
for the server to distinguish an omitted timeout from an explicit request.

This made Docker Compose service `stop_signal` and `stop_grace_period`
ephemeral adapter policy: Compose could use them while issuing a stop, but the
container itself did not retain equivalent defaults for restart, direct CLI, or
other generic clients.

## Required behavior

- Persist optional stop signal and timeout defaults on a container.
- Preserve old saved configuration by decoding a missing timeout as `nil`.
- Resolve caller options first; use persisted defaults only for omitted values.
- Keep the current five-second fallback if no timeout is specified anywhere.
- Make the creation surface generic and usable outside Compose.

## Apple-shaped implementation

The implementation commit is
`8650e5d` (`feat(runtime): persist container stop defaults`). It is limited to
`apple/container` and uses the existing macOS-hosted Linux stop primitive:

- `ContainerConfiguration` owns the persisted defaults.
- Generic run/create flags transport the defaults into that configuration.
- `ContainerStopOptions` represents an omitted timeout as `nil`.
- The API service resolves defaults before passing the request to the runtime.
- The runtime retains its old five-second fallback for no configured value.

No Compose product code is present in the fork and no
`apple/containerization` change is required.

## Scope and non-goals

- Support macOS-hosted Linux containers only.
- Do not add Windows shutdown behavior.
- Do not change explicit `container stop` override semantics.
- Do not implement Docker lifecycle events, state expansion, or restart
  policies as part of this narrow configuration bridge.

## Upstream handoff condition

The code commit is local-only until a batched validation and push. Before an
Apple pull request, replay it onto the current upstream base and rerun the
focused parser tests, staged `TestCLIStop` integration pass, `make check`, and
`make coverage-unit`. Update the commit reference if replay changes it.
