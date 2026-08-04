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
