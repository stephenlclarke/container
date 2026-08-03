# Feature request: add a Docker-compatible AWS Logs provider

## Feature or enhancement request details

The macOS container runtime has an authority-owned remote logging plane, but it
did not provide Docker's `awslogs` driver. A valid Compose request therefore
survived normalization and persistence but could not start a workload using
Amazon CloudWatch Logs.

Add a native provider pinned to the Moby 29.2.1 contract. The API authority
must own AWS credential resolution, CloudWatch connections, batching, and the
existing generation-fenced provider lifecycle.

Expected behavior:

- Require `awslogs-group`; resolve the stream from `awslogs-stream`, `tag`, or
  Docker's `{{.FullID}}` default.
- Resolve region from `AWS_REGION`, allow `awslogs-region` to override it, and
  fall back to EC2 instance metadata.
- Use the AWS default credential chain, or the presence-sensitive ECS-style
  `awslogs-credentials-endpoint` rooted at `169.254.170.2`.
- Honor group/stream creation, endpoint override, `json/emf`, datetime and RE2
  multiline formats, force-flush interval, maximum buffered events, and
  blocking/non-blocking start behavior.
- Preserve CloudWatch's 26-byte event overhead, 1 MiB/10,000-event batch
  limits, 262,118-byte event splitting, UTF-8 effective length, stable
  timestamp ordering, and sequence-token recovery/drop semantics.
- Preserve exact provider identity, idempotency, effect-token, generation,
  fencing, close, and recovery contracts.
- Keep native reads unavailable unless the existing Docker-compatible dual
  cache is explicitly configured.

## Scope and non-goals

This is a generic macOS-hosted CloudWatch Logs provider. It does not add
Compose YAML, a Docker socket or REST API, an AWS service emulator, or a native
CloudWatch reader. Google Cloud Logging, journald, production plugin hosting,
and Engine/gateway integration remain separate slices.

## Upstream publication

The implementation is retained on the local
`upstream/logging-driver-parity` branch. No Apple issue or pull request should
be published until the complete logging/parity programme is ready for its
coordinated upstream handoff.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
