# Compatibility gap: persist container exposed-port metadata

## Compose surface

`services.<name>.expose`

## Docker Compose V2 behavior

Docker Compose V2 preserves each `expose` entry as container port metadata. It
does not create a host listener; `ports` is the separate publishing mechanism.
The accepted values are a port or inclusive port range with an optional `tcp`
or `udp` protocol.

## Existing Apple primitive

The generic `ContainerConfiguration` did not retain exposed ports, so
`container create` and `container run` had no macOS runtime metadata channel
for this Compose feature. OCI Runtime Spec itself has no exposed-port field,
so `containerization` does not need a new primitive.

## Required `container` behavior

- Persist a distinct `[String]` of exposed-port metadata on
  `ContainerConfiguration`.
- Add repeatable `container create/run --expose port[-port][/protocol]`
  options.
- Validate TCP/UDP ports and inclusive ranges, canonicalize the values, and
  de-duplicate them deterministically.
- Decode stored configurations that predate this field with an empty array.
- Keep this metadata independent from host port publishing and labels.

## Non-goals

- Compose-specific types, imports, or protocol handling in the Apple runtime.
- Opening a host listener, allocating a host port, or changing `--publish`.
- Windows container behavior.
