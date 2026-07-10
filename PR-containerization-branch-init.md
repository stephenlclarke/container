<!-- markdownlint-disable MD013 -->

# fix(build): skip immutable containerization checkout init builds

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

SwiftPM returns `version: "unspecified"` for a branch dependency as well as a local edit. `install-init.sh` previously treated both as editable and attempted to build inside SwiftPM's read-only source-control checkout, causing `make integration` to fail before running any integration tests.

## Implementation Details

- Keep the existing `unspecified` check as the first edit-mode signal.
- Require the resolved package's `Package.swift` to be writable before building the custom init image.
- Exit successfully with a clear message for immutable source-control checkouts.
- Quote the resolved path and `cctl` executable.

## Testing

```bash
shellcheck scripts/install-init.sh
scripts/install-init.sh --disable-kernel-install
make check
make integration
```

## Compatibility Notes

Writable local edits keep the existing custom init-image workflow. Released and branch-pinned source-control dependencies no longer trigger an invalid nested build.

## Project Checks

- [x] Tested locally.
- [x] Added Apple-facing issue and PR handoff documentation.
- [x] No Apple remote was pushed.
