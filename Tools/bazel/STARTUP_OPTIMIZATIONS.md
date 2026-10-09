<!-- markdownlint-disable MD013 -->
# Startup investigation and smaller guest helper

## Result

The command helper is 16.3% smaller: 88,341,440 to 73,935,808 bytes in optimized ARM64 builds. It no longer links the complete guest server or host container library. Shared implementations moved unchanged into the existing OS and Netlink libraries; public aliases preserve source compatibility. Existing Cgroup/LCShim targets have their own product, and OCI declares its previously transitive NIOFoundationCompat dependency. Server-only changes no longer compile or link the command helper. Clients must rebuild because the defining module of the shared types changes.

Two alternating nine-trial comparisons did not establish a startup or exec speed improvement from the smaller binary. In the second comparison, old/slim startup medians were 733/734 ms and exec medians were 83/83 ms. Keep the proven footprint and build-dependency benefit without attributing unrelated timing variation to it.

The benchmark harness also hashed fork dependency pins before replacing them with Apple's pins. Every fork update therefore created another Apple workspace and invalidated its local dependency build paths. The cache key now uses the effective stock dependency graph, stock manifest metadata and build-importer inputs. A regression test checks that fork-only pin/manifest changes reuse the key, while stock-pin, extra effective dependency and importer changes invalidate it. The next run creates one workspace under the corrected key; subsequent equivalent fork updates reuse it.

## Final runtime comparison

Median milliseconds, seven successful trials per workload. These are the final pinned Apple/fork measurements. Docker values are the unchanged reference collected earlier in the same optimization session, not a fresh Docker run.

| Workload | Fork | Apple | Docker/Colima reference |
| --- | ---: | ---: | ---: |
| Start, exit and remove | 705 | 541 | 122 |
| Command in running container | 76 | 94 | 34 |
| Warm image import | 44 | 51 | 282 |
| Image export | 83 | 107 | 235 |
| SHA-256, 128 MiB | 472 | 471 | 419 |
| Write and sync, 64 MiB | 200 | 199 | 190 |
| Uncached build | 897 | 871 | 304 |
| Cached build | 142 | 141 | 170 |

Startup remains about 30% slower than Apple. CPU and disk throughput are close. Import/export and warm exec are faster in this run; builds are close to Apple. Docker still has substantially lower startup and command latency. Separate-run differences must not be treated as causal improvements: the alternating old/new guest experiment showed equivalent latency.

## Why startup is slower

With the same Linux kernel file, the fork reached the guest agent after a median 264 ms of kernel boot, versus Apple's 90 ms across three diagnostic runs. Full guest kernel logs show 16 reserved runtime filesystem devices initialized serially, commonly spending 8-12 ms between each PCI device enable and filesystem discovery. These devices preserve live filesystem attachment capacity; they were not removed.

The host already creates the device configurations before starting Linux. Linux must still initialize its drivers. A pool of previously booted VMs could move this cost ahead of a request, but would consume idle resources and require explicit ownership, reset and isolation handling. That architecture was not added in this change.

## Experiments rejected

- Asynchronous `virtio-pci` probing reduced one observed kernel boot to about 52 ms but failed to boot reliably. One run assigned the workload disk to `/dev/vda`, where the current boot command expects the guest system disk. Another trapped inside guest init. All failures and logs remain in the evidence. The Mac host did not crash.
- Linux already calls `wait_for_device_probe()` before mounting the root filesystem and `async_synchronize_full()` before launching init. Adding another all-complete barrier alone cannot make disk naming deterministic. A console-readiness probe did not rescue the experiment; it is not shipped. See the [Linux root-mount code](https://github.com/torvalds/linux/blob/v6.18/init/do_mounts.c) and [init sequence](https://github.com/torvalds/linux/blob/v6.18/init/main.c).
- Parallel probing of only the filesystem driver and expedited RCU during boot did not materially improve startup. Both kernel settings were discarded.
- Raising the agent's soft memory threshold from 80 to 96 MiB did not improve the alternating nine-trial comparison: startup was 733 ms and exec 83 ms, effectively the same as the control. The original 80 MiB setting remains.
- An initial temporary diagnostic archive omitted the existing pre-proc executable-path entry and failed boot. Its results are excluded. The corrected comparison and final archive use the established rootfs layout.

## Validation and limits

All 91 qualified host test suites pass; 23 benchmark-tool tests pass. The moved OS namespace tests and existing host network-contract tests pass; byte comparisons prove both moved implementations unchanged. The optimized Linux guest builds and the final runtime benchmark validates output hashes, workload exit status and cleanup for all eight workloads. The static Linux SDK still lacks the guest Swift Testing module, so guest unit tests are not claimed. Source-format checking reported only a pre-existing guarded force-unwrap in the unchanged network implementation; documentation lint passes.

Both runtime lanes use the same pinned Alpine image and kernel, request 1 CPU/512 MiB, and boot a dedicated VM per container; the runtime adds its normal VM overhead. Builders request 2 CPU/2 GiB. Docker/Colima uses a warm shared 4 CPU/8 GiB VM, so its startup numbers compare practical product behavior with a different isolation architecture. Host: Apple M5 Pro, 24 GiB RAM, macOS 27.0, AC power. See the [previous report](PERFORMANCE_OPTIMIZATIONS.md) for the Docker versions and earlier archive optimizations.

Original Apple service registrations were restored. Benchmark services and temporary build servers are stopped; reusable build caches and evidence remain. No timer or automation was created. The final Linux guest is locally built and fingerprinted; remote publication and CI completion are separate results.

## Exact inputs and evidence

- Container main: `cb30a2e0` (full SHA in evidence).
- Containerization: `7b9eb0a77ff615d764fbbf52125e2b6cdd846db8`.
- Benchmarked Bazel source: `344cc3a717302ff124c6b0d3bbf8c77512c2a950`; later changes only adjust benchmark-cache selection and documentation.
- Apple container: `4a7d8615241b8ddecfd3bf225cd7c44f4b2ccf7c`; Apple containerization: `bc994b88df46207fad7775b0eabc51947e315881`.
- Matching guest archive SHA-256: `d0ede6a2d535c3f5885a09ee207f43169188f98022b52ebd2d843a17a9411f85`.

Evidence: `/Users/sclarke/Library/Application Support/ContainerFamily/retained/container-only/startup-optimizations/20260927T144434Z`. It contains raw trials, fingerprints, failed probes, kernel logs, unchanged-contract hashes and incremental recovery bundles. Source changes are pushed only to Stephen's container/containerization forks. The reduced Bazel branch remains local and is included in the recovery bundle.
