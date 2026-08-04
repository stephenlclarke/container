# Native logging stores reject macOS system directory aliases

## Impact

Logging-v2 containers whose bundle path is expressed below `/tmp` or `/var`
fail during runtime bootstrap. The process-generation ledger accepts those
paths, but the subsequent `json-file` or `local` store open fails with
`ENOTDIR`. Legacy log reads below the same aliases fail for the same reason.

This is observable with an application root below `/tmp`:

```text
io(ContainerLoggingStorage.DockerJSONFileLogIOOperation.open, 20)
```

Darwin exposes `/tmp` and `/var` as immutable system aliases into `/private`.
The secure descriptor-relative traversal correctly uses `O_NOFOLLOW`, but it
was attempting to open those alias components as directories without first
mapping the fixed system spellings to `/private/tmp` or `/private/var`.

## Required behavior

- Accept bundle and log paths below Darwin's fixed `/tmp` and `/var` aliases.
- Preserve `O_NOFOLLOW` traversal for every component after that fixed mapping.
- Continue rejecting arbitrary user-controlled symlinks.
- Apply one consistent rule to `json-file`, `local`, dual-cache, and legacy
  readers.
- Preserve current ownership, mode, regular-file, and link-count validation.

## Reproduction

Create a secure container bundle below the literal `/tmp` spelling, then
activate the `json-file` runtime plan. Before the fix, process-generation
allocation succeeds and opening `logging-v2/json-file` fails with `ENOTDIR`.
The equivalent `local` activation and legacy reader open also fail.

The focused regressions retain the literal alias spelling rather than
canonicalizing the fixture root:

```sh
swift test \
  --filter ContainerLogRuntimePlanTests/darwinSystemDirectoryAliasesPreserveNativeStoreLifecycle
swift test \
  --filter ContainerLogNativeReaderTests/legacyReaderAcceptsDarwinSystemDirectoryAlias
```

## Apple-shaped implementation

Add a package-internal logging-storage helper that maps only the exact `/tmp`
and `/var` system prefixes to `/private`. Use it before component validation in
the secure Docker json-file store, native local store, and legacy reader.

The mapping is deliberately not a general `realpath` operation: arbitrary
symlinks remain rejected rather than silently followed.

## Validation status

Both exact regressions pass on this Apple-silicon Mac:

- native `json-file` and `local` activation, write, close, and static read via
  literal `/tmp` bundle paths;
- legacy static read via a literal `/tmp` bundle path.

The grouped staged runtime replay and broad suite remain deferred until several
related logging slices have accumulated. No Apple issue or pull request has
been published; upstream publication remains gated on completion of all
programme development and explicit authorisation.
