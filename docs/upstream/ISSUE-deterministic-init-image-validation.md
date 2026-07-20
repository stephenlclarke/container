# Reliability gap: init-image validation integration test depends on DNS

## Impact

The `container run` and `container create` integration checks for an invalid
`--init-image` previously used an intentionally nonexistent Internet registry.
That turns a local validation assertion into an unbounded DNS/registry
resolution wait when networking is unavailable or slow. The suite can then
block after otherwise-completed tests and prevent its cleanup and coverage
merge.

## Required Apple behavior

- Validate an invalid OCI image reference before a registry request.
- Cover both `run` and `create` with an invalid `--init-image` value.
- Keep the test self-contained: no external DNS, registry availability, or
  timing assumptions.

## Non-goals

- Change image-pull retry or timeout policy for valid remote references.
- Change the public `--init-image` feature or the configured default image.
- Add Compose-specific behavior to `container`.
