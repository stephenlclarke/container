# Pull request: add generic OCI container annotations

## Summary

- Add separately persisted OCI annotations to `ContainerConfiguration`.
- Add repeatable `--annotation key=value` options to `container create` and `container run`.
- Carry annotations unchanged through the Linux runtime adapter into `containerization`'s OCI specification.
- Preserve backward compatibility for existing serialized container configurations.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | `LinuxContainer.Configuration.annotations` writes an OCI annotations map to the runtime spec. |
| `apple/container` | Generic resource, CLI, and runtime adapter; no Compose dependency. |
| `container-compose` | Separate adapter renders Compose `annotations` as generic `--annotation` options. |

Any macOS client can use this metadata surface. The implementation does not import Compose types or reinterpret Compose configuration.

## Code map

- `Sources/ContainerResource/Container/ContainerConfiguration.swift` adds an `annotations` map and backward-compatible decoding.
- `Sources/Services/ContainerAPIService/Client/Flags.swift` adds the documented repeatable CLI option shared by `create` and `run`.
- `Sources/Services/ContainerAPIService/Client/Utility.swift` parses the options into the resource configuration.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` passes the map to `containerization`.
- `Tests/ContainerResourceTests/ContainerConfigurationTests.swift`, `Tests/ContainerAPIClientTests/ParserTest.swift`, and `Tests/ContainerRuntimeLinuxServerTests/RuntimeServiceHostsTests.swift` cover persistence, parser behavior, and the final adapter boundary.
- `docs/command-reference.md` records the exact user-facing `--annotation <annotation>` help text for both commands.

## Validation

```sh
swift test --disable-automatic-resolution --filter 'ContainerConfigurationResourcesTests|ParserTest|RuntimeServiceHostsTests' --no-parallel
make check
make test
swift run --skip-build container create --help
swift run --skip-build container run --help
```

The focused suite passed with 283 tests; the full local unit suite passed with 1,095 tests. Both generated help commands include `--annotation <annotation>`.

## Compatibility

The option is opt-in. Existing labels remain untouched, and stored configurations without the new field decode to an empty annotations map. An annotation may share a key with a label because they are separate OCI metadata channels.

## Non-goals and risks

This adds the generic macOS OCI primitive only. It intentionally does not emulate Docker Engine's unrelated label storage or add any Windows behavior. The companion Compose change uses its own Docker Compose V2 configuration-parity fixture.

## Commit tracking

- `containerization` primitive, tests, and handoff: `9109cbb8dab85917475f2ab3cecdbee797e2c0ad` (`feat(runtime): add OCI container annotations`).
- `container` code, tests, and command-reference update: `9a75157a0c4ed1497bfb6b4ce8f43f6f1c25f0c8` (`feat(runtime): add OCI container annotations`).
- `container-compose` adapter: pending; it will pin both revisions and reference this handoff.
