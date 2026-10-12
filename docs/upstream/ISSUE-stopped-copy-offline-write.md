<!-- markdownlint-disable MD013 -->

# Stopped regular-file copy-in pays guest startup cost

## Steps to reproduce

Create or stop a dedicated-VM container with its private, unmounted rootfs and copy a regular host file into it. The retained runtime-v8 observations show 621.172 ms and 620.671 ms for created and exited containers. Both exceed the corresponding retained Docker observation by more than ten times.

## Problem description

The existing copy-only guest preserves lifecycle correctness but incurs boot and agent-connect costs even when a private stopped image can be updated offline. Resource tuning did not demonstrate a useful improvement. The SDK Formatter creates a filesystem and cannot safely update an existing image.

A faster path must retain byte, mode, ownership, destination-directory and overwrite semantics; exclude mounted/shared/running images; serialize against start/prewarm/delete; and leave the original intact on every precommit failure. Unsupported cases must use the existing guest implementation. Raw failures and published baseline artifacts/results must remain immutable.

## Environment

Apple silicon macOS, Container source based on c9c53650fcc49601d078e00ac78a548dd83dcf50, published Containerization dependency 518f92a006c94c55e21422f3cf2f93c2f039d053. Independent component fixture provenance records its content hash; its original producer commit was not retained. This is a local upstream-shaped handoff, not a submitted Apple issue.
