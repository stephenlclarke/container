<!-- markdownlint-disable MD013 -->

# Offline EXT4 copy helper

`container-ext4-copy` is a standalone GPL-2.0-or-later executable statically linked with pinned e2fsprogs 1.47.4 sources. The original upstream archive, including all original licenses and notices, and the exact helper source/build recipe accompany the executable in `container-ext4-copy.source.tar.gz`. No libext2fs code is linked into the Swift service, SDK or guest.

Build with `make offline-ext4-helper` or the Bazel `//Tools/ContainerOfflineExt4:payload` target. Native builds authenticate the same upstream source archive as Bazel. Configure explicitly uses bundled uuid/blkid sources; no Homebrew headers, libraries, package discovery or dynamic runtime is used. The manifest records the source pin, compiler, library and helper hashes and build commands. `build.py verify --output-dir DIRECTORY` verifies the executable/source hashes and system-only dynamic linkage. The deterministic test target requires an existing helper, an independent clean extent-based EXT4 fixture and explicit test-only e2fsprogs tools. It does not install tools or create a substitute oracle. Supply all three paths:

```sh
make test-offline-ext4-helper \
  OFFLINE_EXT4_TEST_FIXTURE=/path/to/independent.ext4 \
  OFFLINE_EXT4_TEST_FSCK=/path/to/e2fsck \
  OFFLINE_EXT4_TEST_DEBUGFS=/path/to/debugfs
```

`OFFLINE_EXT4_BUILD_DIR` may select a previously built helper directory. The target runs source-policy tests, sandbox denials, process deadlines/memory exhaustion/reaping and the filesystem cases. Retain its complete output when qualifying a candidate.

The versioned invocation is `container-ext4-copy --protocol=1 DESTINATION SOURCE_BASENAME MODE UID GID CREATE_PARENTS PRESERVE_OWNERSHIP`. Numeric fields are decimal. The parent explicitly passes a private staged image read/write as descriptor 3 and a regular source file read-only as descriptor 4. The helper opens no host pathname, reads the source with bounded `pread` calls, and returns 0 only after flushing and syncing the staged image. Exit 2 rejects the invocation or descriptors; exit 3 requests the existing guest path. Unsupported or failed operations may have changed staging; the caller must discard it.

The service must hold its per-container lifecycle mutation slot until the helper is reaped, verification completes and commit or cleanup finishes. It owns rootfs eligibility, source opening, private sibling cloning, result readback, identity revalidation, atomic replacement and directory sync. A helper success is not a commit. Running, prewarmed, mounted or shared images must never be passed to the helper.

The initial regular-file path supports new files, overwrites, existing destination directories and parent creation. Path-dependent symlinks, dot components, journal recovery, ACL inheritance and special inode flags use the guest implementation. These are routing boundaries, not parity waivers. Directory/archive copies remain on the guest path. Before parsing filesystem metadata the helper applies a deny-default macOS sandbox that permits file contents only for the staged image, the read-only source and `/dev/null`. Host metadata reads remain allowed; other file-content reads, writes, process launches and network access are denied. This uses the deprecated `sandbox_init` API. Failure to establish confinement selects the guest implementation; there is no unsandboxed parser fallback. Negative tests exercise these restrictions.

The helper sets a 30-second CPU limit. Its parent samples resident and charged physical memory every millisecond and kills/reaps a child above 256 MiB or on a monitoring failure. This host rejects 256 MiB `RLIMIT_DATA` and `RLIMIT_AS` limits, which include virtual mappings rather than just charged memory. Sampling permits transient overshoot; this is not a hard virtual-memory quota. Timeout or exhaustion discards staging and selects the guest path.

The sandbox constrains host access, but the parser can write the entire staged image. Independent SDK readback verifies the requested file, not every unrelated inode. It does not prove that an exploited parser could not corrupt other staged filesystem entries. The original remains unchanged until verified atomic replacement. Distribution-license closure remains a separate release qualification requirement.
