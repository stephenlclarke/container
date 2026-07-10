<!-- markdownlint-disable MD013 -->

# [Request]: Distinguish branch checkouts from editable containerization dependencies

## Feature or enhancement request details

`scripts/install-init.sh` uses `swift package show-dependencies --format json` to decide whether `containerization` is in local edit mode. SwiftPM reports `version: "unspecified"` for both editable path dependencies and source-control dependencies pinned to a branch.

When `containerization` is branch-pinned, its resolved path is under `.build/checkouts/` and SwiftPM intentionally marks checkout files read-only. Treating that checkout as editable makes `make integration` run `make -C .build/checkouts/containerization init`, which fails while updating the nested Swift build database and dSYM property lists.

The script should build and install a custom init image only when the resolved package is a writable local edit. A read-only source-control checkout should be skipped because the normal package/runtime artifacts already own that dependency lane.

## Acceptance criteria

- A writable local `containerization` edit still builds and installs `vminit:latest`.
- A branch-pinned SwiftPM checkout exits successfully without trying to modify `.build/checkouts/containerization`.
- A missing path still fails with a clear diagnostic.
- Paths containing spaces remain quoted.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
