# Container machines

## What it is

`container run` runs an **application**. A **container machine** is a Linux **environment**
you work inside.

The difference that matters: a container machine boots the image's init system, so it can run
long-running services under a process supervisor, and it maps your macOS username into Linux.
Your macOS home directory remains available at its host path (normally `/Users/<username>`),
separate from the machine's Linux home at `/home/<username>`. Repos stored in the mounted host
home are present on both platforms at the same time.
Edit with your macOS editor; compile and run inside Linux; point macOS-native profilers,
browsers, and GUI debuggers at the same files. There is no copy step between building
something and inspecting it.

When you want a Linux shell on your Mac rather than a single containerized application, this
is the tool — use it instead of Lima or Colima.

## Getting a shell

```bash
container machine create alpine:latest --name dev
container machine run -n dev                  # interactive shell as your host user
container machine run -n dev uname -a         # one command, then exit
container machine run -n dev -- cat /proc/cpuinfo   # use -- when the command takes flags
```

`container machine run` is the way in. It boots the container machine first if it is stopped.
You do not SSH into a container machine.

Inside, `whoami` returns your host username. When the command starts from a directory inside
the mounted macOS home, `container machine run` preserves that `/Users/<username>/...`
working directory. Outside the mounted home, or when the home mount is disabled, it falls
back to the machine user's Linux home at `/home/<username>`. An explicit `--workdir` takes
precedence.

## Setting a default

```bash
container machine set-default dev
container machine run                          # no -n needed
```

## Lifecycle

```bash
container machine ls                 # list
container machine inspect dev        # JSON detail
container machine logs dev           # boot and console logs
container machine stop dev
container machine rm dev             # deletes its storage too
```

`container machine` has the alias `m`, so `container m ls` and
`container m run` work.

## Sizing and the home mount

`--cpus` and `--memory` at create time; `container machine set` afterward. Memory defaults to
half of host memory. `--home-mount` takes `rw` (default), `ro`, or `none`.

```bash
container machine create alpine:latest --name dev --cpus 8 --memory 16G --set-default
container machine set -n dev cpus=4 memory=8G
container machine stop dev            # set takes effect on the next boot
container machine run -n dev -- nproc
```

`container machine set` changes configuration on disk. It does **not** apply to a running
container machine — stop it, then `run` to reboot.

## Services under an init system

On an image with `systemd`, a container machine runs it, so system services work:

```bash
container machine run -n dev -- sudo systemctl start postgresql
container machine run -n dev -- systemctl status postgresql
```

This is the main reason to reach for a container machine over `container run` for a
development stack: dependencies live where a process supervisor manages them.

## One container machine per target distro

Each machine gets its own Linux `$HOME`. The same mounted macOS home is available at
`/Users/<username>` in every machine, so repositories and dotfiles stored there can be shared
across init-enabled distribution images:

```bash
container machine create alpine:latest --name alpine
container machine create local/ubuntu-machine:latest --name ubuntu
```

## Custom images

Any Linux image with `/sbin/init` works. Build one like any other image:

```bash
container build -t local/ubuntu-machine:latest .
container machine create local/ubuntu-machine:latest --name ubuntu
```

For a `systemd` image, the Dockerfile needs `dbus` and `systemd` installed,
`systemctl set-default multi-user.target`, and several units masked
(`dev-hugepages.mount`, `sys-fs-fuse-connections.mount`, `systemd-update-utmp.service`,
`systemd-tmpfiles-setup.service`, `console-getty.service`). The complete working Dockerfile is
in the project's `docs/container-machine.md`.

## Nested virtualization

Requires Apple silicon M3 or later, macOS 15 or later, and a kernel built with `CONFIG_KVM=y`
— the default kernel does not have it.

```bash
container machine create --virtualization --kernel /path/to/vmlinux-kvm --name kvm-dev alpine:latest
container machine run -n kvm-dev -- ls -l /dev/kvm
```

Toggle on an existing container machine, then reboot it:

```bash
container machine set -n dev virtualization=true kernel=/path/to/vmlinux-kvm
container machine stop dev
container machine set -n dev kernel=          # reset to the default kernel
```
