# Approved upstream PR ports

This fork carries the approved upstream changes below so the Stephen-owned container stack can release against them before Apple merges and publishes equivalent commits. These notes are for future upstream submission or removal when the Apple changes land. Do not push these commits to Apple from this fork.

## apple/container#730: accept global flags after subcommands

- Upstream PR: <https://github.com/apple/container/pull/730>
- Local status: ported with an additional parse-entry correction.
- Local delta: the approved PR normalizes `--debug` in `ContainerCLI.run()`, but this fork's `@main` wrapper delegates directly to `Application.main()`. The fork therefore also normalizes arguments inside `Application.main(arguments:)`, before `Application.parseAsRoot(_:)`, and keeps `ContainerCLI.run()` delegated to the same helper.
- Validation: `swift test --disable-automatic-resolution --filter ApplicationHealthTests` covers argument normalization and root-help detection. `CONTAINER_CLI_PATH="$PWD/.build/debug/container" swift test --disable-automatic-resolution --filter TestCLIHelp` covers `container help`, `container --debug help`, and `container help --debug`.

## apple/container#1660: exclude application data from backups

- Upstream PR: <https://github.com/apple/container/pull/1660>
- Local status: ported through `ApplicationRoot.ensureCreated(at:log:)` and invoked from API server startup before service route setup.
- Local delta: the upstream patch was authored around `ContainersService`; this fork centralizes the behavior at the application root helper because the API server already owns root initialization.
- Validation: `swift test --disable-automatic-resolution --filter ApplicationRootTests` checks directory creation and the `isExcludedFromBackup` resource value.

## apple/container#1708: document `[machine]` system configuration

- Upstream PR: <https://github.com/apple/container/pull/1708>
- Local status: ported to `docs/container-system-config.md`.
- Local delta: wording was kept ASCII-only and clarifies that `container machine set` changes require stopping and restarting the machine before they take effect.
