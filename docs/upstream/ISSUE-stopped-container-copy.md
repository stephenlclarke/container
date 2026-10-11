# Issue: copying files requires a running container

## Problem

Every `ContainersService.copyIn` and `copyOut` overload rejects a container whose public status is not running. A created container therefore cannot receive a configuration file before its first start, and a stopped container cannot return files without executing its workload again. The sparse-file commit probe exposes this as `invalidState: container ... is not running` when copying a file after stopping its source container.

## Steps to reproduce

Create a container with a file in its root filesystem, start and stop it, then run `container cp <name>:/path/to/file ./copied-file`. Alternatively, create a container and copy a host file into it before its first start. Both operations are rejected by the current API service.

## Expected behavior

Copying into or out of created and stopped containers should access the persisted filesystem without executing the container workload, changing its public lifecycle state, or emitting a workload start. Copy-in changes must survive a later start. Existing directory, sparse logical content, hardlink, symlink, mode and ownership semantics should remain consistent with the corresponding running copy operations.

## Environment and evidence

The retained failure occurred in the Container candidate before this fix and is also present in stock Apple code. A pinned Docker Engine 29.5.2 oracle confirms created and exited copy-in/out, persistence through a later start, 32 MiB sparse logical content, directory hardlinks, default symlink preservation and explicit symlink following. The complete Docker state record remains unchanged across each copy phase, and a never-started workload marker remains absent. The oracle records image identity, monotonic command durations and exact logs; all owned resources and displaced host services were restored afterward.

## Scope

Use the existing guest copy operations with safe runtime ownership and per-container lifecycle serialization. Preserve the workload state and fail explicitly for provider capabilities that cannot implement the operation. Do not reconstruct an existing EXT4 filesystem through an incomplete archive round-trip, start the user's workload as a shortcut, or claim complete Docker copy parity from these focused cases.

The mode-corrected candidate passed 39 selected file/archive XML cases. The full differential oracle still records a roughly 29x first-copy slowdown against Docker. Its initial full log-bundle comparison also raced background create prewarming, which initializes metadata independently of copying. Separate cold and fully prewarmed fixtures now pass while isolating the copy boundary; the original failure remains retained. The completed isolated differential run then exposed a standalone symlink copied as a regular file. The candidate now pins the SDK and guest symlink correction; changed-candidate end-to-end proof remains pending.

See the [proposed correction](PR-stopped-container-copy.md). No Apple issue or pull request has been submitted for this work.
