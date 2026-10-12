# Committing a container changes command override behavior

## Description

A container started from an image with no entrypoint and `Cmd: ["/bin/sh"]` is committed with `Entrypoint: ["/bin/sh"]` and an empty command. Running the committed image with `echo hello` then invokes the shell with those arguments instead of replacing the default command. Multi-element image entrypoints and explicit overrides also lose their original split.

## Reproduction

1. Start an Alpine container with a positional command such as `sleep infinity`.
2. Commit the container to a new image.
3. Inspect the image configuration and run it with a new positional command.

## Expected behavior

The committed image retains the effective entrypoint and command independently, including explicit empty entrypoints. A later positional command replaces only the saved command. The split survives container configuration persistence.

## Actual behavior

`OCIImageArchive.create` always uses the executable as a one-element entrypoint and the remaining runtime arguments as the command. Runtime argv cannot identify the original split: an inherited multi-element entrypoint and a shorter explicit override can produce identical argv.

## Context

Tracked by [apple/container #2350](https://github.com/apple/container/issues/2350). The pinned Moby `docker-v29.2.1` commit implementation retains the container configuration during commit; this is supporting source evidence. Live Docker and candidate CLI qualification remains required at the final matched-stack checkpoint.
