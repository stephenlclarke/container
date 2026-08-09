# Bootstrap gap: an isolated Container root cannot load its first init image before services start

## Impact

For a fresh isolated application root, `container system start` installed the
configured initial filesystem only by pulling it from the registry. Loading a
known local OCI archive first was impossible because `container image load`
itself needs the services that `system start` has not yet created. A matching
source build consequently had an unnecessary registry/authentication
dependency before its public Docker socket could start.

## Required behavior

- Accept an explicit OCI archive for the configured initial filesystem.
- When that filesystem is absent, load and unpack the archive before the
  registry fallback.
- Reject a missing archive, rejected archive members, or an archive without
  the configured image with a concrete CLI error.
- Preserve the existing registry path when no archive is supplied.

## Non-goals

- Change the configured default image, registry authentication, or ordinary
  image-load behavior after startup.
- Treat an archive as a replacement for normal image verification.
- Change Docker Compose policy.

## Local implementation

Signed local commit `e048dc19d54e25aa3887689d0015d5af447d4ad5`
(`feat(system): bootstrap init filesystem from archive`) adds
`container system start --init-image-archive <path>`. It loads the OCI archive,
requires the configured image reference, and unpacks the current platform
before the normal registry pull is considered.

## Publication state

This is an Apple-shaped local issue handoff on
`upstream/logging-driver-parity`. Do not create an Apple issue or submit a pull
request until the complete Container-family programme is ready and the user
explicitly authorises the coordinated upstream publication wave.
