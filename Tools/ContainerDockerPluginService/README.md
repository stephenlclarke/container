# Container Docker Logging-Plugin Service

This directory contains the Linux/arm64 service that bridges Container's
generation-fenced logging authority to the official Docker logging-plugin
protocol. It is not a plugin installer. An approved plugin bundle embeds this
service and its plugin in one pinned OCI workload.

## Installed bundle contract

An installed Container logging plugin supplies these protected resource files:

- `container-docker-logging-plugin.manifest.json`
- `container-docker-logging-plugin.oci.tar`

The manifest pins the provider identity/generation, driver names, `ReadLogs`
capability, stable service endpoint identity, source digest, OCI archive
digest, and exact Linux/arm64 image-manifest digest. Container rejects unknown
manifest fields, writable or symbolic-link assets, digest mismatches, name or
port collisions, and stale service generations before advertising the driver.

The pinned image must provide
`/usr/local/libexec/container-docker-plugin-entrypoint`. That plugin-owned
entrypoint receives the service arguments, starts the plugin so it owns the
manifest's private Unix socket, starts this service with the unchanged
arguments, forwards termination, and does not expose the plugin socket outside
the workload. The service binary accepts:

```text
--sandbox-generation GENERATION
--provider-id ID
--provider-generation GENERATION
--contract-digest DIGEST
--plugin-socket /absolute/private/plugin.sock
--port VSOCK_PORT
--listen-unix /run/container-engine/service-VSOCK_PORT.sock
--authentication-key-file /var/lib/container-docker-plugin-service/authentication.key
```

Container mounts one provider-generation state directory at
`/var/lib/container-docker-plugin-service`. The 32-byte request key and durable
claim state are mode 0600; directories and FIFO roots are mode 0700. The key is
not supplied through arguments, environment, manifests, or diagnostics. The
workload root filesystem remains read-only; private tmpfs mounts at `/run` and
`/tmp` provide only the volatile paths required for the plugin socket, FIFO
root, and ordinary temporary files.

## Behavior

The installed workload listens on the private Unix path and uses the shared
sandbox's out-of-workload relay to reach the protected per-user Engine socket.
The numeric port remains the stable endpoint identity and the standalone
service retains AF_VSOCK as a fallback when `--listen-unix` is omitted.

The service:

- authenticates every bounded, versioned request before durable state, plugin,
  FIFO, or listener initialization;
- caches only a successful exact `Capabilities` response for the process
  lifetime so every writer and reader uses one stable plugin contract without
  repeated control-plane calls;
- durably claims writer and reader identity before FIFO, HTTP, or stream
  effects;
- uses real deterministic Linux FIFOs and Docker's four-byte big-endian
  protobuf `LogEntry` frames;
- calls `StopLogging` before graceful FIFO removal and revokes the FIFO before
  an authoritative fence;
- routes direct `ReadLogs` streams with sequence-stable response replay;
- durably records exact provider-history migration receipts only for the
  installed contract and a plugin advertising `ReadLogs`;
- proves writer and reader claims are empty before acknowledging exact
  provider-generation reclamation;
- releases a newly claimed writer after a definitive plugin rejection so an
  idempotent replay can retry safely, while retaining non-definitive starts as
  uncertain ownership;
- makes uncertain plugin effects visible instead of issuing a potentially
  duplicate `StartLogging` or `ReadLogs` call after a service crash;
- bounds connections, replay memory, state, requests, responses, frames,
  writers, and readers.

Independent Container sessions use a bounded persistent connection pool.
Writer calls are suspension-safe: one session admits only one `write`, `flush`,
`close`, or `fence` operation at a time, and advances its sequence only after
the service accepts the frame. Concurrent stdout and stderr pumps therefore
cannot reuse one sequence for different Docker frames.

Once the service authenticates and accepts a mutating request, that operation
runs under the service lifetime rather than the transient connection lifetime.
A peer HUP can discard the reply, but cannot cancel an in-progress
`StartLogging`, write, close, fence, migration, or reclamation effect; the
operation ledger serves the replay. The blocking `nextReader` operation remains
connection-cancellable so a disconnected reader does not remain parked. A
connection already known to be closed is rejected before any buffered request
is admitted.

The host connector admits the sandbox and protected service workload once per
connection attempt. After the exact workload generation is running, only its
dial and generation probe are retried during the readiness window. A terminal
workload-start error therefore returns immediately instead of allocating new
operation or process generations in a tight loop.

Blocked FIFO writes wait in the kernel rather than spin and observe peer
disconnect/cancellation. A cancelled caller waiting for a busy connection lane
is removed immediately. Provider service crashes fail only their exact
sessions; authority-led reconciliation fences or closes those durable claims.

## Validation

From this directory on the development Mac:

```sh
go test -race -cover ./...
go vet ./...
```

The macOS unit boundary currently reports 70.2% statement coverage. The
Linux-only FIFO, Unix HTTP plugin, authentication-key, private-listener,
cancellation, and connection-watch tests run in the pinned Linux/arm64 Go
image:

<!-- markdownlint-disable MD013 -->
```sh
docker run --rm --platform linux/arm64 \
  -v "$PWD:/src" -w /src \
  golang@sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e \
  go test -race -cover ./...
```
<!-- markdownlint-enable MD013 -->

That lane currently reports 74.1% statement coverage. It exercises the real
kernel FIFO and official `Capabilities`, `StartLogging`, `StopLogging`, and
`ReadLogs` endpoints against both readable and write-only Unix plugins. The
write-only conformance test proves that a plugin advertising `ReadLogs: false`
is never sent a `ReadLogs` request.
