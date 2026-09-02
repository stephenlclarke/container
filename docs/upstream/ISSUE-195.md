# Issue 195: pin the reviewed Containerization upstream sync

## Problem

The Container Compose 0.14.1 fail-fast preflight found the Containerization
support fork behind Apple upstream. Containerization issue
[#67](https://github.com/stephenlclarke/containerization/issues/67) and pull
request [#68](https://github.com/stephenlclarke/containerization/pull/68)
merged the current Apple stdio and logging changes, then corrected reusable
vsock-slot lifecycle defects exposed by review and Linux compilation.

Container must pin that reviewed merge before Compose can publish a matched
stable stack.

The same release preflight reports Dependabot alert #39 for the semantic
helper's indirect `google.golang.org/grpc` dependency. Versions through 1.83.0
are vulnerable to heap exhaustion from fragmented HTTP/2 DATA frames; 1.83.1
contains the upstream correction.

## Scope

- Update the Containerization revision in the Swift package manifest and
  lockfile.
- Advance the semantic helper to `google.golang.org/grpc` 1.83.1 and the
  compatible indirect module graph.
- Preserve every Container runtime source and behavior unchanged.
- Prove exact dependency resolution and targeted client compilation before
  using the new Container head in Compose.

## Acceptance evidence

- SwiftPM resolves Containerization at
  `f77f8d2833b54498546c081a0a5d15b4751b62bd`.
- `ContainerRuntimeClient` compiles with automatic resolution disabled.
- `go test ./...` passes in `Tools/ContainerSemanticHelper`.
- Dependabot alert #39 closes after the reviewed change reaches `main`.
- Hosted required checks and an exact-head review pass before merge.
