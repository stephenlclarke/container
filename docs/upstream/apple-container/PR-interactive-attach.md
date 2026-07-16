# Apple PR Handoff: Reattach Running Init-Process Streams

## Summary

Add a generic `ContainerClient.attach(id:stdio:)` path for the init process of
a running container. The request adds client streams to durable runtime-owned
relays; it never recreates the process or replaces its guest-side standard
streams.

## Scope

- Add server-owned input and output relay types at runtime bootstrap.
- Keep configured log writers active while fanning live stdout/stderr to
  attached client handles.
- Add XPC routes through the Container API and runtime services.
- Reuse the existing init-process resize, signal, and wait endpoints from the
  attached client.
- Provide a minimal `container attach [--no-stdin] ID` consumer for runtime
  verification.

## Deliberately out of scope

- Compose service selection, `--detach-keys`, and Compose signal policy.
- Replay of bytes emitted before an attach session begins.
- Reattachment to arbitrary exec processes or a remote/network stream API.

## Design notes

`stdin`, `stdout`, and `stderr` are established in the guest only once, when
the init process starts. The new relays are therefore server-owned for that
whole lifetime. A disconnect removes only that client's handles; it cannot
close the guest stdin or stop future clients from attaching.

TTY containers retain the normal merged stdout path. Non-TTY containers retain
separate stdout and stderr streams. Existing local log capture stays a
persistent output writer rather than becoming an attach-client side effect.

## Fork commit mapping

- `feat(runtime): reattach running init-process streams`
- `test(runtime): cover attach stream relays`

## Validation

- `swift test --filter RuntimeAttachIOTests`
- `swift build --target ContainerRuntimeLinuxServer`
- `swift build --target ContainerCommands`
- A real-runtime detached TTY attach/re-attach smoke before upstream handoff.

## Upstream reference

- <https://github.com/apple/container/issues/378>
