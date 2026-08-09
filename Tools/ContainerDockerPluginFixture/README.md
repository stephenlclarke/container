# Docker Logging-Plugin Certification Fixture

This directory builds a deterministic Linux/arm64 OCI workload containing the
production Container Docker logging-plugin lifecycle service and an independent
readable Docker logging plugin. It exists only to certify the installed plugin
contract; it is not a built-in driver or a production plugin.

The fixture implements Docker's `Capabilities`, `StartLogging`, `StopLogging`,
and `ReadLogs` endpoints on a private Unix socket. It consumes the real
length-prefixed protobuf FIFO stream, fsyncs the frames to the generation's
protected state mount, and returns those exact frames through `ReadLogs`.

`build.py` pins the builder, runtime image, Dockerfile frontend, platform,
source digests, OCI archive digest, workload manifest digest, provider identity,
generation, private socket, and service port. Its output can be installed under
an isolated Container install root for the whole-stack lifecycle gate.

After starting that isolated system, `certify.py` proves installed catalogue
discovery, public Docker create/start/stop/delete, two native lifecycle cycles,
one public lifecycle cycle, exact three-cycle FIFO history, stopped-state
projection, and independent Docker `info`, `inspect`, and `logs` access:

```sh
python3 Tools/ContainerDockerPluginFixture/certify.py \
  --container /path/to/isolated/bin/container \
  --docker-host unix:///path/to/docker.sock \
  --require-state-projection
```

The runner refuses to replace an existing container and always attempts to
remove only its exact certification container before it exits.
