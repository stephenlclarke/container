# Customize `container` default configuration values

Take a guided tour of setting configurations for `container` CLI commands and
services.

## Configuration sources

The `container` service loads values from these TOML files at startup, with
first-match-wins precedence:

1. Your user file at `~/.config/container/config.toml`.
2. An optional file shipped with the `container` package install at
   `<installRoot>/etc/container/config.toml`.

Any key absent from both files falls back to a hardcoded default. For the full
schema and defaults, see the
[`config.toml` reference](../container-system-config.md).

## Create a custom user TOML configuration file

The `container` service reads your file once at startup, so restart the service
whenever you want changes to take effect.

### Open or create your config file

Your editable config lives at `~/.config/container/config.toml`. Create it if it
does not exist:

```bash
mkdir -p ~/.config/container
touch ~/.config/container/config.toml
```

### Set the values you want to customize

Open the file in the editor of your choice and add only the sections and keys
you want to change.

For this tutorial, increase the default CPU and memory limits used for each new
container and set a DNS domain for resolving container IP addresses from the
host.

```toml
[container]
cpus = 8
memory = "4g"

[dns]
domain = "test"
```

The service also accepts authority-owned logging-v2 defaults. Logging options
use adjacent name and value entries rather than a TOML table so arbitrary
provider keys and values survive decoding without `=` parsing:

```toml
[logging]
driver = "json-file"
options = ["max-size", "10m", "max-file", "3", "tag", ""]
```

The logging-v2 runtime capability is not advertised yet. At this implementation
checkpoint the section is loaded and shown in the merged configuration, but
legacy container creation and logging remain unchanged until server-side
resolution and the v2 writer are enabled.

Each top-level table maps directly to a section of
[ContainerSystemConfig](../container-system-config.md).

### Restart the `container` service

To make your edits take effect, stop and start the system:

```bash
container system stop
container system start
```

### Verify the values are loaded

Use `container system property list` (alias `ls`) to print the merged
configuration that the `container` service is using.

```console
% container system property list
diagnosticKind = "container-system-config-inspection-v1"

[build]
cpus = 2
memory = "2048mb"
rosetta = true
image = "ghcr.io/stephenlclarke/container-builder-shim/builder@sha256:09bdaafcffcde28e3022ff65ef5ae3a6502022b3c9735a9b4f45acb17d054d3d"

[container]
cpus = 8
memory = "4gb"

[dns]
domain = "test"

[kernel]
binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.15-186"
url = "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"
digest = "sha256:f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91"

[logging]
diagnosticKind = "logging-config-inspection-v1"
driver = "json-file"
protectedOptionCount = 3
protectedOptionNames = ["max-file", "max-size", "tag"]

[logging.safeOptions]

[network]

[registry]
domain = "docker.io"

[vminit]
image = "ghcr.io/apple/containerization/vminit:0.37.0"
```

For machine-readable output, pass `--format json`:

```bash
container system property list --format json
```

`container system property list` omits logging option values unless the selected
provider has classified them as safe. It reports protected option names and a
count, never synthetic placeholder values. The output has a diagnostic
discriminator and cannot be loaded as authoritative configuration. The
`driver` identity is shown unchanged. Configuration sources use
first-match-wins precedence per key, so a higher-precedence `[logging].driver`
can combine with the complete adjacent name/value `[logging].options` array
from a lower-precedence file; option entries are not merged one by one.
