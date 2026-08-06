<!-- markdownlint-disable MD013 -->

# Runtime gap: Docker GELF host alias on the native macOS provider

## Problem

Docker Engine accepts a GELF address such as `tcp://host.docker.internal:12201` and starts the container because Docker's GELF driver connects from its Linux VM. Container accepts the same public Docker API create request, but the native GELF provider runs on macOS and passed that VM-only hostname directly to NIO. On the programme MBP, macOS resolves it with `EAI_NONAME`, so `docker start` fails with `container logging operation failed` before the provider writes a record.

The gap applies to both TCP and UDP. It is a native transport-placement issue: the Docker-visible logging configuration must remain `host.docker.internal`, while the host-side provider needs a local connection target.

## Required behavior

- Preserve the configured GELF endpoint verbatim in Docker API create, inspect, and persisted state.
- At the native macOS GELF transport boundary only, map `host.docker.internal` case-insensitively to IPv4 loopback before opening TCP or UDP sockets.
- Keep empty-host handling and all non-Docker hostnames unchanged.
- Do not change Docker Engine route projection, endpoint parsing, guest `/etc/hosts`, or non-macOS transport behavior.

## Acceptance evidence

- [x] Docker Engine 29.2.1 / Docker CLI 29.7.1 reconnect oracle starts with `tcp://host.docker.internal:PORT`, drops the first connection, and recovers a subsequent GELF stream.
- [x] A focused `GELFTransportLoopbackTests.productionDockerHostAliasRoutesTCPAndUDPToNativeLoopback` regression passes through the matched local Containerization `38d9c69` and Engine API `4949e743` graph.
- [ ] Build a fresh signed Container archive from the final source commit and run the public Docker CLI reconnect certificate twice through the native socket.
- [ ] Compare the exact candidate timing with the retained Docker reference, update the gap-only ledger, and complete the clean checkpoint review.

## Local evidence

The focused test was executed with `CONTAINERIZATION_PACKAGE_PATH=/Users/sclarke/Documents/container/containerization-engine-sandbox`, `CONTAINERIZATION_REF=38d9c69`, and `CONTAINER_ENGINE_API_PACKAGE_PATH=/Users/sclarke/github/container-engine-api`. The marker-protected test log is `/private/tmp/container-gelf-native-alias-unit-matched.D850uv/swift-test.log`. The unmodified Docker reference reconnect certificate is retained at `/private/tmp/container-gelf-tcp-reconnect-reference-v2.yjav2A/docker-reference-result.json`.

The Stephen-owned tracking issue is [stephenlclarke/container#75](https://github.com/stephenlclarke/container/issues/75). It is intentionally separate from this Apple-shaped handoff.

## Apple-shaped boundary

The implementation is retained locally on `upstream/logging-driver-parity`. No Apple issue, pull request, branch publication, or push has been created. Do not publish it until all parity development waves are complete and the user explicitly authorises the coordinated upstream publication.

Related pull-request handoff: `docs/upstream/PR-gelf-native-host-alias.md`.

<!-- markdownlint-enable MD013 -->
