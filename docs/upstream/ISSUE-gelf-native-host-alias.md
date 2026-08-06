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
- [x] A fresh signed Container archive from `2a60d0ad0341ef6947d30289488e3a7c8eac56ed` passes the public Docker CLI reconnect certificate twice through the native socket.
- [x] The exact candidate timings are compared with the retained Docker reference and the gap-only ledger records the clean checkpoint review.

## Local evidence

The focused test was executed with `CONTAINERIZATION_PACKAGE_PATH=/Users/sclarke/Documents/container/containerization-engine-sandbox`, `CONTAINERIZATION_REF=38d9c69`, and `CONTAINER_ENGINE_API_PACKAGE_PATH=/Users/sclarke/github/container-engine-api`. The marker-protected test log is `/private/tmp/container-gelf-native-alias-unit-matched.D850uv/swift-test.log`. The unmodified Docker reference reconnect certificate is retained at `/private/tmp/container-gelf-tcp-reconnect-reference-v2.yjav2A/docker-reference-result.json` and passed in `5.524841000s`.

`/private/tmp/container-gelf-tcp-reconnect-candidate-v2.nmMgi1` is the marker-protected final evidence root. Its `FINGERPRINT-PREFLIGHT.json`, `ARCHIVE-VERIFICATION.json`, and `FINGERPRINT-COMPLETE.json` bind the exact source/dependency graph, code-signed archive, binaries, guest images, harness, wrapper, Docker reference, and two isolated public-socket runs. The candidate runs passed in `6.508964500s` and `6.340717583s` (1.18x and 1.15x Docker). They satisfy the focused fixture's 10x functional guard; programme-wide comparable-or-better release performance remains a separate gap.

The Stephen-owned tracking issue is [stephenlclarke/container#75](https://github.com/stephenlclarke/container/issues/75). It is intentionally separate from this Apple-shaped handoff.

## Apple-shaped boundary

The implementation is retained locally on `upstream/logging-driver-parity`. No Apple issue, pull request, branch publication, or push has been created. Do not publish it until all parity development waves are complete and the user explicitly authorises the coordinated upstream publication.

Related pull-request handoff: `docs/upstream/PR-gelf-native-host-alias.md`.

<!-- markdownlint-enable MD013 -->
