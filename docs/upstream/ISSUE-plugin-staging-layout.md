# Runtime qualification installs two plugins under paths the CLI does not dispatch

## Impact

Runtime qualification currently stages the native `container-build` and `container-builder` products under plugin directories with those same names. The Makefile installs them under `plugins/build/bin/build` and `plugins/builder/bin/builder`, which are the names dispatched by the CLI. A qualified candidate can therefore fail at runtime with an unknown-command error for `builder`.

## Required behavior

- Stage the two plugins at the same paths used by the Makefile.
- Keep signing identifiers and entitlement lookups tied to the native product names.
- Continue accepting historical measured-product v2 layouts without rewriting their paths or bytes.
- Record new measured installations as layout v3 and restore native filenames for the release packaging recipe.
- Preserve plugin executables in runtime coverage under their native filenames.

## Non-goals

- Change native build products, package recipes, product signing identities, or dependency layers.
- Re-run historical benchmark samples or relabel their measured executable paths.

## Compatibility

Historical `container-executables-v2` fingerprints retain their original plugin paths. The new v3 layout changes only the installed paths of `container-build` and `container-builder`; all other products retain their existing paths.
