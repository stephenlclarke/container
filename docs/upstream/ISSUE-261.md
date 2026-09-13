# Homebrew package omits required Container Engine assets

## Problem

The signed Homebrew release archive contains the `container-engine` gateway,
semantic helper, and Engine-Linux logging service archives, but the maintained
formula installs only the Container CLI, API server, and plugin directory. A
Homebrew installation therefore fails during `container system start` when
`SystemStart` resolves the required sibling `container-engine` executable. The
installed API server also reports the journald and GELF service archives as
unavailable.

## Reproduction

1. Install `stephenlclarke/tap/container` 0.15.1.
2. Confirm that the downloaded release archive contains
   `bin/container-engine`, `libexec/container/helpers`, and
   `libexec/container/services`.
3. Confirm those paths are absent from the installed Homebrew prefix.
4. Run `container system start` and observe the startup failure after the
   machine API check.

## Required behavior

- Install the signed `container-engine` executable beside `container` and
  `container-apiserver`.
- Install the complete staged `libexec/container` tree so plugins, helpers,
  and Engine-Linux service archives remain a coherent release unit.
- Retain the separately installed lifecycle helper.
- Make the Homebrew formula test fail when any required gateway, helper, or
  service asset is omitted.
- Continue to generate release formulae from the one maintained template.

## Acceptance evidence

- [ ] Formula-updater unit tests prove the complete runtime asset contract.
- [ ] Ruby syntax and Homebrew audit pass.
- [ ] A package archive installation contains the gateway, semantic helper,
  and journald/GELF service archives.
- [ ] `container system start`, Engine `/_ping`, and clean shutdown pass from
  the installed prefix.
- [ ] The repaired formula is propagated to `stephenlclarke/homebrew-tap` by
  the release workflow.

## Tracking

- Issue: <https://github.com/stephenlclarke/container/issues/261>
