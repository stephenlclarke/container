# Pull request: add generic container exposed-port metadata

## Summary

- Persist exposed-port metadata on `ContainerConfiguration`.
- Add repeatable `--expose <port>` options to `container create` and
  `container run`.
- Validate and canonicalize port, range, and TCP/UDP forms without opening a
  host listener.
- Preserve compatibility with existing serialized container configurations.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | No change: the OCI Runtime Spec has no exposed-port primitive. |
| `apple/container` | Generic resource, CLI, validation, and persistence only; no Compose dependency. |
| `container-compose` | Separate adapter forwards `services.expose` as generic `--expose` options. |

The runtime owns the reusable metadata primitive. The Compose project remains
an adapter and neither project imports types from the other.

## Code map

- `Sources/ContainerResource/Container/ContainerConfiguration.swift` adds the
  persisted field and backward-compatible decoding.
- `Sources/Services/ContainerAPIService/Client/Flags.swift` adds the
  documented repeatable option shared by `create` and `run`.
- `Sources/Services/ContainerAPIService/Client/Parser.swift` validates,
  canonicalizes, sorts, and de-duplicates exposed ports.
- `Sources/Services/ContainerAPIService/Client/Utility.swift` writes parsed
  metadata into the generic container configuration.
- `Tests/ContainerAPIClientTests/ParserTest.swift` and
  `Tests/ContainerResourceTests/ContainerConfigurationTests.swift` cover
  accepted forms, rejection paths, flag parsing, persistence, and legacy
  decoding.
- `docs/command-reference.md` captures the exact generated `create` and `run`
  help text.

## Validation

```sh
swift test --disable-automatic-resolution --filter 'ParserTest|ContainerConfigurationResourcesTests' --no-parallel
make test
make coverage-unit
make check
.build/debug/container create --help
.build/debug/container run --help
```

The focused suite passed 256 tests, the full local unit suite passed, the unit
coverage report was regenerated, and both generated help commands list
`--expose <port>`.

## Compatibility

The option is opt-in. Stored configurations without `exposedPorts` decode as
an empty array. `tcp` is canonicalized to the protocol-free default form;
`udp` is retained. Exposed ports never allocate or bind host ports, so current
publish behavior is unchanged.

## Non-goals and risks

This is the macOS generic metadata capability required by Compose, not a
Docker Engine emulation layer. It intentionally excludes Windows behavior and
does not alter networking, listeners, OCI specs, or labels. The companion
Compose PR carries its own Docker Compose V2 fixture and dry-run parity check.

## Commit tracking

- `container` code, tests, and command-reference update:
  `2f7b6e4d207027f5b44a27070e0baddbbe42fb76`
  (`feat(runtime): add container exposed-port metadata`).
- `container-compose` adapter: pending; it will pin this commit and reference
  this handoff.
