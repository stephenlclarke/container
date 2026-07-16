# Reattach Standard Streams to a Running Container

## Summary

Add a narrow Container API primitive that lets a new client attach stdin,
stdout, and stderr to an already-running init process. This closes the runtime
gap behind `container compose attach` without teaching `apple/container` any
Compose syntax or project policy.

## Motivation

The initial process previously received client-owned pipes only when it was
started. A detached client leaves no process stream that a later client can
join, so log following could approximate output but could not provide
interactive stdin, terminal resizing, or terminal-compatible stdout/stderr.

Compose owns service/index lookup, `--detach-keys`, and Compose command
semantics. The runtime needs only a session-safe way to join the original init
process's standard streams.

## Proposed runtime shape

- The runtime creates server-owned input and output relay objects during
  bootstrap, even when the process starts detached.
- The output relays retain configured log capture and fan future bytes to each
  currently attached client.
- The input relay accepts client data without closing the guest stdin when one
  client disconnects.
- A new `ContainerClient.attach(id:stdio:)` request passes client stream
  descriptors through the API service to the runtime.
- Existing process resize and signal APIs remain the process-control surface;
  attach does not create or restart a process.

## Deliberately out of scope

- Docker/Compose `--detach-keys` parsing. That is a client-side terminal
  concern and belongs in the Compose layer.
- Historical log replay. `container logs` remains the persistent replay API;
  attach carries live bytes after session creation.
- Attaching arbitrary exec processes, multi-user authorization policy, or a
  network-facing stream protocol.

## Validation

- Start a detached interactive TTY container, attach, send input, resize the
  terminal, detach, and attach again without restarting the process.
- Verify output reaches both the initial client and a later attached client.
- Verify ending one input session does not close stdin for a later session.
- Verify local logging continues while no client is attached.

## References

- Existing request: <https://github.com/apple/container/issues/378>
- Compose consumer: `container compose attach`
