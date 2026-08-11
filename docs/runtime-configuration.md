# Runtime configuration

Configure what runs inside and around your container's init process: Linux
capabilities, path masking, nested virtualization, and the init process itself.

## Control Linux capabilities

By default, containers start with a restricted set of Linux capabilities:

`CAP_AUDIT_WRITE`, `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_FOWNER`, `CAP_FSETID`, `CAP_KILL`, `CAP_MKNOD`, `CAP_NET_BIND_SERVICE`, `CAP_NET_RAW`, `CAP_SETFCAP`, `CAP_SETGID`, `CAP_SETPCAP`, `CAP_SETUID`, `CAP_SYS_CHROOT`

You can customize the capability set using `--cap-add` and `--cap-drop` with `container run` or `container create`.

Capability names can be specified with or without the `CAP_` prefix, and are case-insensitive:

These are equivalent:
```bash
container run --cap-add CAP_NET_ADMIN alpine ip link set lo down
container run --cap-add NET_ADMIN alpine ip link set lo down
container run --cap-add net_admin alpine ip link set lo down
```

To grant all capabilities:

```bash
container run --cap-add ALL alpine sh -c "ip link set lo down && echo ok"
```

`--privileged` grants the process the runtime's extended Linux capability set
directly:

```bash
container run --privileged alpine sh -c "ip link set lo down && echo ok"
```

This flag affects the process capability set. Use explicit mount, network,
security, and device flags for other isolation boundaries.

To drop all capabilities and selectively re-add only what you need:

```bash
container run --cap-drop ALL --cap-add SETUID --cap-add SETGID alpine id
```

Adds are processed after drops, so `--cap-drop ALL --cap-add ALL` results in all capabilities being granted.

To grant all capabilities except specific ones:

```bash
container run --cap-add ALL --cap-drop NET_ADMIN alpine sh
```

To drop a single capability from the default set:

```console
% container run --cap-drop CHOWN alpine chown 100 /tmp
chown: /tmp: Operation not permitted
```

## Add supported Linux VM devices

Use `--device` with `container run` or `container create` to add a Linux device
path supported by the Apple runtime VM bridge:

```bash
container run --device /dev/null:/dev/xnull:rw alpine sh -c "test -c /dev/xnull"
container run --device /dev/zero:rw alpine sh -c "test -c /dev/zero"
```

The format is `HOST[:CONTAINER[:PERMISSIONS]]`. When the second field is only an
access string such as `rw`, it is treated as permissions and the container path
defaults to the host path. This exposes supported Linux VM device paths; it does
not provide USB, SD-card, PCI, or arbitrary macOS hardware passthrough.

Use `--device-cgroup-rule` when you only need to adjust Linux device cgroup
permissions without creating another device node:

```bash
container run --device-cgroup-rule "c 1:3 mr" alpine true
```

## Request the Apple virtio-gpu device

Use `--gpus` with `container run` or `container create` to request the single
paravirtual virtio-gpu device exposed by Virtualization.framework:

```bash
container run --gpus all alpine sh -c "ls /sys/class/drm /dev/dri 2>/dev/null || true"
container create --gpus device=0 alpine true
```

Supported Docker-compatible forms are `all`, `count=1`, `device=0`, and the
explicit `driver=virtio` equivalent. Requests for multiple GPUs, other device
IDs, vendor drivers, driver options, or extra capabilities are rejected before
the container VM is created.

The option enables the lower-runtime virtio-gpu device and requires the guest to
expose `/dev/dri/renderD128` before the workload starts. This is paravirtual
graphics-device support, not proof of hardware-accelerated rendering and not
direct Metal, CUDA, NVIDIA, PCI, or arbitrary macOS GPU passthrough. Workloads
still need compatible Linux userspace graphics libraries.

## Mask and protect paths inside a container

> [!NOTE]
> `--masked-path` and `--read-only-path` are experimental. The behavior described here is subject to change in a future release.

By default, containers hide a set of sensitive paths from the workload, and mark another set read-only, matching the OCI runtime spec defaults that other production runtimes apply.

Masked by default (files are replaced with `/dev/null`, directories with an empty read-only tmpfs):

`/proc/asound`, `/proc/acpi`, `/proc/kcore`, `/proc/keys`, `/proc/latency_stats`, `/proc/timer_list`, `/proc/timer_stats`, `/proc/sched_debug`, `/proc/scsi`, `/sys/firmware`, `/sys/devices/virtual/powercap`

Read-only by default:

`/proc/bus`, `/proc/fs`, `/proc/irq`, `/proc/sys`, `/proc/sysrq-trigger`

You can extend either set using `--masked-path` and `--read-only-path` with `container run` or `container create`. Both flags can be repeated, take absolute paths, and add to the defaults rather than replacing them:

```console
% container run --masked-path /etc/alpine-release alpine cat /etc/alpine-release
% container run --read-only-path /tmp alpine touch /tmp/file
touch: /tmp/file: Read-only file system
```

To opt out of the defaults entirely, pass the `NONE` sentinel. It clears every path accumulated so far for that flag, including the defaults:

```bash
container run --masked-path NONE alpine ls /sys/firmware
```

Because values are processed in order, `NONE` can be followed by a custom set that replaces the defaults:

```bash
container run --masked-path NONE --masked-path /run/secrets alpine sh
```

The two flags are independent, so clearing the masked paths leaves the read-only defaults in place. The paths that a container was created with are visible in `container inspect` under `configuration.maskedPaths` and `configuration.readonlyPaths`; when neither flag is used, both are absent and the runtime defaults apply.

## Expose virtualization capabilities to a container

> [!NOTE]
> This feature requires a M3 or newer Apple silicon machine and a Linux kernel
> that supports virtualization. For a kernel configuration with the required
> features, see
> <https://github.com/apple/containerization/blob/main/kernel/config-arm64>.

You can enable virtualization capabilities in containers by using the `--virtualization` option of `container run` and `container create`.

If your machine does not have support for nested virtualization, you will see the following:

```console
container run --name nested-virtualization --virtualization --kernel /path/to/a/kernel/with/virtualization/support --rm ubuntu:latest sh -c "dmesg | grep kvm"
Error: unsupported: "nested virtualization is not supported on the platform"
```

When nested virtualization is enabled successfully, `dmesg` will show output like the following:

```console
container run --name nested-virtualization --virtualization --kernel /path/to/a/kernel/with/virtualization/support --rm ubuntu:latest sh -c "dmesg | grep kvm"
[    0.017245] kvm [1]: IPA Size Limit: 40 bits
[    0.017499] kvm [1]: GICv3: no GICV resource entry
[    0.017501] kvm [1]: disabling GICv2 emulation
[    0.017506] kvm [1]: GIC system register CPU interface enabled
[    0.017685] kvm [1]: vgic interrupt IRQ9
[    0.017893] kvm [1]: Hyp mode initialized successfully
```

## Run a container with a provided init process

By default, the command you specify in `container run` runs as PID 1 inside the container. This means it is responsible for reaping zombie processes and handling signals, which many applications are not designed to do. The `--init` flag runs a lightweight init process as PID 1 that automatically forwards signals and reaps orphaned child processes.

```bash
container run --init ubuntu:latest my-app
```

The init process is also available with `container create`:

```bash
container create --init --name my-container ubuntu:latest my-app
container start my-container
```

## Use a custom init image

The `--init-image` flag allows you to specify a custom init filesystem image for the lightweight VM that runs your container. This enables:

- Custom boot-time logic before the OCI container starts
- Running additional processes and daemons (e.g., eBPF network filters, logging agents) inside the VM
- Debugging or instrumenting the init process

### Create a custom init image

A custom init image wraps the default `vminitd` binary, allowing you to run custom logic before handing off to the standard init process.

**1. Create a wrapper binary (example in Go for easy cross-compilation):**

```go
// wrapper.go
package main

import (
    "os"
    "syscall"
)

func main() {
    // Write a message to kernel log
    kmsg, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0)
    if err == nil {
        kmsg.WriteString("<6>custom-init: === CUSTOM INIT IMAGE RUNNING ===\n")
        kmsg.Close()
    }

    // Execute the real vminitd
    err = syscall.Exec("/sbin/vminitd.real", os.Args, os.Environ())
    if err != nil {
        os.Exit(1)
    }
}
```

**2. Build the wrapper for Linux arm64:**

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o wrapper wrapper.go
```

**3. Create a Containerfile:**

Use the `vminit` image tag corresponding to the `scVersion` value in the project `Package.swift` file.

Or, use `vminit:latest` if you have a local `containerization` project in [edit mode](../BUILDING.md#develop-using-a-local-copy-of-containerization).

```dockerfile
FROM ghcr.io/apple/containerization/vminit:0.40.1 AS base

FROM ghcr.io/apple/containerization/vminit:0.40.1
COPY --from=base /sbin/vminitd /sbin/vminitd.real
COPY wrapper /sbin/vminitd
```

**4. Build the custom init image:**

```bash
container build -t local/custom-init:latest .
```

### Run a container with a custom init image

```bash
container run --name my-container --init-image local/custom-init:latest alpine:latest echo "hello"
```

### Verify the custom init is running

Check the VM boot logs to confirm your custom init code executed:

```console
% container logs --boot my-container | grep custom-init
[    0.129230] custom-init: === CUSTOM INIT IMAGE RUNNING ===
```

See [Logs](./logs.md) for more on viewing container and VM boot logs.
