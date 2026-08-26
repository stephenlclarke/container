<!-- markdownlint-disable MD013 MD060 -->

# `config.toml` reference

For a guided walk-through on setting default values, see [Container system config tutorial](./tutorials/container-system-config-tutorial.md).

Source of truth: [`Sources/ContainerPersistence/ContainerSystemConfig.swift`](../Sources/ContainerPersistence/ContainerSystemConfig.swift).

## Viewing your configuration

Use `container system property list` (alias `ls`) to print the merged configuration
the `container` service is actually using — combining your `config.toml` with
hardcoded defaults for anything you haven't set:

```console
% container system property list
diagnosticKind = "container-system-config-inspection-v1"

[build]
cpus = 2
memory = "2048mb"
rosetta = true
image = "ghcr.io/stephenlclarke/container-builder-shim/builder@sha256:d81d12e1dca1133ede535483a809803e6b256555a73d17f207003279539454a4"

[container]
cpus = 4
memory = "1gb"

[dns]
domain = "test"

[kernel]
binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"
url = "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"
digest = "sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"

[logging]
diagnosticKind = "logging-config-inspection-v1"
driver = "json-file"
protectedOptionCount = 0
protectedOptionNames = []

[logging.safeOptions]

[network]

[registry]
domain = "docker.io"

[vminit]
image = "ghcr.io/stephenlclarke/containerization/vminit:7e4f5152e9606a34a92c34186eb94f7cd37c134f"
```

Pass `--format json` for machine-readable output.

## Top-level schema

```toml
[build]      # builder VM resources and image
[container]  # default per-container resources
[dns]        # default DNS domain for DNS resolution on host
[kernel]     # guest kernel binary path, download URL, and digest
[logging]    # default logging driver and options for future logging-v2 creates
[machine]    # default per-machine resources and home mount
[network]    # default subnets for new networks
[registry]   # default registry domain
[vminit]     # default vminitd image to use
[plugin.<id>]  # zero or more plugin-scoped sections
```

All top-level sections are optional. Omitted sections fall back to their defaults wholesale.

## `[build]`

Resources and image used for the builder VM that runs `container build`.

| Key       | Type        | Default                                              | Description                                                                 |
|-----------|-------------|------------------------------------------------------|-----------------------------------------------------------------------------|
| `rosetta` | `Bool`      | `true`                                               | Whether the builder VM uses Rosetta translation for non-native architectures. |
| `cpus`    | `Int`       | `2`                                                  | CPU count for the builder VM.                                              |
| `memory`  | [MemorySize](#memorysize-format)  | `"2048mb"`                                           | RAM allocation for the builder VM. |
| `image`   | `String`    | bundled builder repository plus digest when available | Reference for the builder image. `stephenlclarke` release builds use the compiled `container-builder-shim` repository and digest; custom builds without a digest fall back to the compiled repository and tag. |

To prevent the use of Rosetta translation during container builds on a Mac with Apple
silicon, set `rosetta = false`:

```toml
[build]
rosetta = false
```

This ensures builds only produce native arm64 images, with no x86_64 emulation.

## `[container]`

Defaults applied when `container run` / `container create` is invoked without `--cpus` or `--memory`.

| Key      | Type       | Default | Description                                                                |
|----------|------------|---------|----------------------------------------------------------------------------|
| `cpus`   | `Int`      | `4`     | Default CPU count per container.                                           |
| `memory` | [MemorySize](#memorysize-format) | `"1g"`  | Default RAM per container. |

## `[dns]`

| Key      | Type      | Default | Description                                                                |
|----------|-----------|---------|----------------------------------------------------------------------------|
| `domain` | `String?` | unset   | Local DNS domain appended to container hostnames (e.g. `"test"` makes `my-web-server` resolvable as `my-web-server.test`). When unset, no domain is appended. See [Networking: Set up DNS-based container names](./networking.md#set-up-dns-based-container-names) for the full walkthrough. |

## `[kernel]`

Guest kernel used when launching container VMs. Defaults change per release as kernels are bumped — check the [source](../Sources/ContainerPersistence/ContainerSystemConfig.swift) for current values.

| Key          | Type      | Default                                                                                                | Description                                                                  |
|--------------|-----------|--------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| `binaryPath` | `String`  | `"opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"`                                           | Path **inside** the downloaded kernel archive that points to the kernel binary. |
| `url`        | `URL`     | `"https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"` | Archive to download when no kernel is installed. Encoded and decoded as a plain string in TOML. |
| `digest`     | `String`  | `"sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"`                             | Expected digest for the archive, for example `sha256:<hex>`. Required when configuring a custom `url`. |

## `[logging]`

Authority-owned defaults for logging-v2 container creation. This configuration
is loaded when the Container service starts. The logging-v2 runtime capability
is not advertised yet, so these values are accepted and reported now but do not
replace the legacy local/none create and writer path until the capability is
enabled.

```toml
[logging]
driver = "json-file"
options = ["max-size", "10m", "max-file", "3"]
```

| Key       | Type       | Default       | Description |
|-----------|------------|---------------|-------------|
| `driver`  | `String`   | `"json-file"` | Default driver identity. Arbitrary provider names are preserved; availability is resolved authoritatively during logging-v2 container creation. |
| `options` | `[String]` | `[]`          | Adjacent option-name and option-value entries. Empty names and values, `=` characters, dots, and arbitrary strings are preserved without parsing; an odd number of entries or a duplicate name is rejected. |

Configuration-file precedence is evaluated independently for `driver` and
`options`. For example, a user file that sets only `driver` combines with an
`options` key from a lower-precedence installation file. The `options` array is
one configuration key; entries are not merged individually across files.

Logging option values may contain credentials. `container system property list`
therefore omits values that have not been classified as safe and reports only
their sorted names and count. It never inserts a placeholder value that could
be mistaken for authoritative configuration. The diagnostic object has an
explicit `diagnosticKind` and cannot be loaded as system configuration. The
source `config.toml` remains authoritative and must be protected with
appropriate file permissions.

## `[machine]`

Defaults applied when `container machine create` is invoked without `--cpus`, `--memory`, or `--home-mount`.
Does not affect existing machines -- use `container machine set` to update an existing machine, then stop and restart it for changes to take effect.

| Key         | Type       | Default                                              | Description                                                                        |
|-------------|------------|------------------------------------------------------|------------------------------------------------------------------------------------|
| `cpus`      | `Int`      | `max(processorCount / 2, 4)`                         | Default CPU count per machine.                                                     |
| `memory`    | [MemorySize](#memorysize-format) | Half of host physical memory (min 1 GiB)             | Default RAM per machine.                                                           |
| `homeMount` | `String`   | `"rw"`                                               | Home directory mount mode: `"rw"` (read-write), `"ro"` (read-only), or `"none"` (no mount). |

## `[network]`

Default subnets used when creating networks without explicit `--subnet` / `--subnet-v6` flags.

| Key        | Type       | Default | Description                                                                                       |
|------------|------------|---------|---------------------------------------------------------------------------------------------------|
| `subnet`   | [CIDRv4?](#cidrv4--cidrv6)  | unset   | IPv4 CIDR (e.g. `"192.168.100.0/24"`). When unset, the system auto-allocates a non-overlapping subnet. |
| `subnetv6` | [CIDRv6?](#cidrv4--cidrv6)  | unset   | IPv6 CIDR (e.g. `"fd00:abcd::/64"`). When unset, the system auto-allocates.                       |

## `[registry]`

| Key      | Type     | Default      | Description                                                                                                  |
|----------|----------|--------------|--------------------------------------------------------------------------------------------------------------|
| `domain` | `String` | `"docker.io"` | Registry assumed when an image reference omits the registry host (e.g. `alpine` → `docker.io/library/alpine`). |

## `[vminit]`

| Key     | Type     | Default                                                | Description                                                                                              |
|---------|----------|--------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `image` | `String` | Source-dependent immutable reference | Reference for the `vminitd` image used to boot container VMs. Apple builds select the bundled Containerization version; custom builds with an exact Containerization revision select `ghcr.io/<source>/vminit:<revision>`. |

## `[plugin.<id>]`

Plugins can ship their own configuration schemas under `[plugin.<id>]`, where `<id>` is the plugin's identifier. Each plugin defines and reads its own section — values under one plugin's section cannot leak into another's. Consult the documentation for the specific plugin you want to configure.

| Key                | Type     | Notes                                                                                       |
|--------------------|----------|---------------------------------------------------------------------------------------------|
| `<plugin-defined>` | varies   | Schema, defaults, and examples are defined by the plugin that owns the identifier. |

## Type formats

### MemorySize format

Quoted string with a numeric prefix and a binary unit suffix. Parsing is case-insensitive; the suffix may be one of:

| Suffix family       | Unit                     | Example values         |
|---------------------|--------------------------|------------------------|
| `b`                 | bytes                    | `"1024b"`              |
| `k`, `kb`, `kib`    | kibibytes (1024 bytes)   | `"512k"`, `"512kb"`    |
| `m`, `mb`, `mib`    | mebibytes (1024 KiB)     | `"2048mb"`             |
| `g`, `gb`, `gib`    | gibibytes (1024 MiB)     | `"4g"`, `"4gb"`        |
| `t`, `tb`, `tib`    | tebibytes                | `"1t"`                 |
| `p`, `pb`, `pib`    | pebibytes                | `"1p"`                 |

All units are **binary** (powers of 1024), even when written with `kb`/`mb`/`gb`. The encoded form uses lowercase suffix `b`/`kb`/`mb`/`gb`/`tb`/`pb`, e.g. a value parsed from `"2g"` is emitted as `"2gb"`.

A bare integer (e.g. `"2048"`) parses as bytes.

Source: [`Sources/ContainerPersistence/Measurement+Parse.swift`](../Sources/ContainerPersistence/Measurement+Parse.swift).

### `CIDRv4` / `CIDRv6`

Quoted string. IPv4 example: `"192.168.100.0/24"`. IPv6 example: `"fd00:abcd::/64"`. The loader rejects invalid CIDR strings at decode time.
