<!-- markdownlint-disable MD033 -->
<h1>
  <img
    alt="Containerization logo"
    src="./assets/Containerization-Logo.png"
    width="70"
    valign="middle">
  &nbsp;container
</h1>
<!-- markdownlint-enable MD033 -->

`container` is a tool that you can use to create and run Linux containers as
lightweight virtual machines on your Mac. It's written in Swift, and optimized
for Apple silicon.

The tool consumes and produces
[OCI-compatible container images](https://github.com/opencontainers/image-spec),
so you can pull and run images from any standard container registry. You can
push images that you build to those registries as well, and run the images in
any other OCI-compatible application.

`container` uses the
[Containerization](https://github.com/apple/containerization) Swift package for
low-level container, image, and process management.

The `stephenlclarke` fork supplies the runtime and CLI for the matched
[`container-compose`](https://github.com/stephenlclarke/container-compose)
release stack. That repository owns the canonical
[stack map](https://github.com/stephenlclarke/container-compose#project-repositories),
[current dependency pins](https://github.com/stephenlclarke/container-compose/blob/main/STATUS.md),
and [release policy](https://github.com/stephenlclarke/container-compose/blob/main/BRANCHES.md).
`container system version` reports the exact runtime, `containerization`, and
builder-shim revisions in an installed package.

![introductory movie showing some basic commands](./docs/assets/landing-movie.gif)

## Get started

### Requirements

You need a Mac with Apple silicon to run `container`. To build it, see the
[BUILDING](./BUILDING.md) document.

`container` is supported on macOS 26, since it takes advantage of new features
and enhancements to virtualization and networking in this release. We do not
support older versions of macOS and the `container` maintainers typically will
not address issues that cannot be reproduced on macOS 26.

### Initial install

Download the latest signed installer package for `container` from the
[GitHub release page](https://github.com/apple/container/releases).

To install the tool, double-click the package file and follow the instructions.
Enter your administrator password when prompted, to give the installer
permission to place the installed files under `/usr/local`.

The `stephenlclarke` fork also publishes a prebuilt Homebrew package. Follow
[HOMEBREW.md](HOMEBREW.md) for the supported matched-stack install path.

Start the system service with:

```bash
container system start
```

### Network interface names

When attaching a network, `interface=NAME` assigns a stable name to its
interface inside the Linux guest. For example:

```bash
container run --network default,interface=frontend alpine:latest ip link show frontend
```

### Additional interface addresses

Repeat `address=IP` in a network attachment to configure additional IPv4 or
IPv6 addresses inside the guest. Addresses without an explicit prefix use
Docker-compatible address masks (`/16` for IPv4 and `/64` for IPv6):

```bash
container run \
  --network default,address=198.51.100.8,address=2001:db8::8/64 \
  alpine:latest ip address show
```

### Requested primary interface addresses

Use `ip=IPv4` or `ip6=IPv6` in a network attachment to request its primary
address. The address must be an allocatable member of the network's configured
subnet; the network service reserves it so later dynamic allocations cannot
reuse it. Values are addresses, not CIDRs:

```bash
container run --network backend,ip=192.0.2.8,ip6=2001:db8::8 alpine:latest ip address show eth0
```

### Upgrade or downgrade

For both upgrading and downgrading, you can manually download and install the
signed installer package by following the steps from
[initial install](#initial-install) or use the `update-container.sh` script
(installed to `/usr/local/bin`).

If you're upgrading or downgrading, you must stop your existing `container`:

```bash
container system stop
```

To upgrade to the latest release, simply run the command below:

```bash
/usr/local/bin/update-container.sh
```

To downgrade, you must uninstall your existing `container` (the `-k` flag keeps
your user data, while `-d` removes it):

```bash
/usr/local/bin/uninstall-container.sh -k
/usr/local/bin/update-container.sh -v MAJOR.MINOR.PATCH
```

Start the system service with:

```bash
container system start
```

### Uninstall

Use the `uninstall-container.sh` script (installed to `/usr/local/bin`) to
remove `container` from your system. To remove your user data along with the
tool, run:

```bash
/usr/local/bin/uninstall-container.sh -d
```

To retain your user data so that it is available should you reinstall later, run:

```bash
/usr/local/bin/uninstall-container.sh -k
```

## Next steps

- Take [a guided tour of `container`](./docs/tutorials/start-here.md) by
  building, running, and publishing a simple web server image.
- Learn how to [use various `container` features](./docs/how-to.md).
- Read a brief description and [technical overview](./docs/technical-overview.md)
  of `container`.
- Browse the [full command reference](./docs/command-reference.md).
- [Build and run](./BUILDING.md) `container` on your own development system.
- View the project [API documentation](https://apple.github.io/container/documentation/).

## Contributing

Contributions to `container` are welcome and encouraged. Please see our
[main contributing guide](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md)
for more information.

## Project Status

The container project is under active development. Source and CLI stability is
guaranteed within a patch release line; minor releases may contain breaking
changes while the project remains pre-1.0.
