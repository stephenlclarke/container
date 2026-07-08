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

Stephen Clarke's fork is part of a four-repository preview stack:

- [`container`](https://github.com/stephenlclarke/container): this fork-backed
  runtime and CLI.
- [`container-compose`](https://github.com/stephenlclarke/container-compose):
  the Docker Compose style plugin installed beside the matching runtime lane.
- [`containerization`](https://github.com/stephenlclarke/containerization): the
  Swift runtime package consumed by this CLI and by `container-compose`; this
  fork records the matching `containerization` pin for the current stack lane.
- [`container-builder-shim`](https://github.com/stephenlclarke/container-builder-shim):
  the Go BuildKit bridge used by `container build`; this package pins the
  immutable builder image version, currently `0.13.6`, and release builds can
  override the repository or version with `BUILDER_SHIM_REPOSITORY` and
  `BUILDER_SHIM_VERSION`.

The aggregate Homebrew tap is
[`homebrew-tap`](https://github.com/stephenlclarke/homebrew-tap). It tracks the
four source repositories on `main` for maintenance and installs prebuilt
release-quality package assets for users. Go artifacts across the stack are
treated as release code, not debug helpers.

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

Stephen Clarke's fork also publishes Homebrew-ready stable release archives
through the aggregate tap without requiring Xcode or Swift on the target
machine:

```bash
brew tap stephenlclarke/tap
brew install stephenlclarke/tap/container
```

The current branch, tag, and Homebrew policy for this four-repository stack
lives in
[`container-compose/BRANCHES.md`](https://github.com/stephenlclarke/container-compose/blob/main/BRANCHES.md).
New work targets `main`; branch-derived formula lanes are historical only.

Start the system service with:

```bash
container system start
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
/usr/local/bin/update-container.sh -v 0.3.0
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

The container project is currently under active development. Its stability, both
for consuming the project as a Swift package and the `container` tool, is only
guaranteed within patch versions, such as between 0.1.1 and 0.1.2. Minor version
releases may include breaking changes until we reach a 1.0.0 release.
