# Candidate Container services collide across app roots

## Impact

Container's default per-user launchd/Mach labels are stable, so an explicitly
isolated app root does not by itself isolate the API server, Machine API,
images, runtime, network, Engine, or public Docker socket. A candidate
`container system stop` can therefore remove an unrelated user-owned Container
runtime that uses the default service namespace.

The required behavior is narrowly scoped: an opt-in candidate service
namespace must derive every relevant service label and Engine socket; start,
status, stop, clients, and plug-ins must use that one namespace; the default
configuration must retain stock labels and socket behavior; and a stop must
enumerate and remove only services under the selected namespace.

## Apple-shaped implementation

Signed local commit `c740a8f6a79ce176d03a941f49cdfe7350625a71` adds a
validated `CONTAINER_SERVICE_NAMESPACE` selection layer. It retains
`com.apple.container` for the default case, rejects invalid or overly long
custom labels, derives API, Machine API, Core Images, runtime, network, and
Engine labels plus a namespace-specific socket, and routes system lifecycle,
client, and plug-in service discovery through that selection.

This is a generic Container lifecycle and service-ownership correction. The
Compose runner is only the reproducer and consumer; it should not own any
wildcard launchd cleanup or compensate for Container's service identity.

## Focused regressions and live evidence

```sh
CONTAINERIZATION_PACKAGE_PATH=/Users/sclarke/Documents/container/containerization-engine-sandbox \
CONTAINER_ENGINE_API_PACKAGE_PATH=/Users/sclarke/github/container-engine-api \
swift test --enable-code-coverage \
  --filter 'ContainerServiceNamespaceTests|SystemStartTests|SystemStopValidationTests'
```

The focused command passed 19 tests; `ContainerServiceNamespace.swift` is at
100% line, function, and region coverage. Bash syntax, ShellCheck, and
`Tests/ScriptTests/TestInstallInit.sh` also passed.

The paired marker-protected candidate used namespace
`io.github.stephenlclarke.container-compose.runtime.a46377784f5464874269b3ca`,
answered Docker CLI `29.7.1|29.2.1|linux` on its derived socket, and removed
only its own services. The pre-existing user `devcontainer-engine` remained
responsive before and after cleanup. The full certificate is retained in
Container Compose's
`docs/parity/handoffs/RUNTIME-ISOLATED-PUBLIC-SOCKET-01.md`.

## Publication state

No Apple issue or pull request has been published. This local Apple-shaped
handoff remains pending until all programme development is complete and the
user explicitly authorises upstream publication.
