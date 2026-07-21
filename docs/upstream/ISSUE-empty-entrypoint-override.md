# Compatibility gap: clear an image entrypoint while retaining its command

## Compose surface

`services.<name>.entrypoint: []`

## Docker Compose V2 behavior

Docker Compose V2 preserves an explicit empty `entrypoint` list in `config --format json`. When it creates the container, Docker clears the image `Entrypoint` while retaining the image `Cmd`. This is distinct from omitting `entrypoint`, which inherits both image values, and from supplying a non-empty entrypoint override.

## Existing Apple primitive

`container` already resolves an image configuration's entrypoint and command into the initial Linux process. It did not expose a generic way to deliberately omit the image entrypoint while still using the image command. No change to `containerization` is needed.

## Required `container` behavior

- Add `container run/create --clear-entrypoint`.
- Omit the image entrypoint and retain the image command when the flag is set.
- Reject combining `--clear-entrypoint` with `--entrypoint`, because the requested process is ambiguous.
- Preserve all existing behavior when the new flag is absent.

## Non-goals

- Compose-specific product code or a Compose-only runtime protocol.
- Changing the existing non-empty `--entrypoint` behavior.
- Windows container semantics.
