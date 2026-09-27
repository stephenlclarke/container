# Slow service registration queries

## Current and expected behavior

Read-only launchctl queries spend about 70 ms in Foundation run-loop waiting after the command has returned output. Container startup repeatedly performs these checks. Keep ownership validation and domain selection, but wake directly on process termination. Reproduce using launchctl managername and print with read-output-then-wait versus a termination handler.

## Environment and evidence

macOS Apple silicon; pinned Bazel optimized builds. Retained measurements: ContainerFamily/retained/container-only/performance-investigation/20260927. See the matching PR document.
