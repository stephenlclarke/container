# Homebrew

The `stephenlclarke` package is distributed through
[`stephenlclarke/homebrew-tap`](https://github.com/stephenlclarke/homebrew-tap)
as the runtime dependency of the matched `container-compose` plugin. Homebrew
installs prebuilt packages; it does not build this Swift source on the user's
machine.

Use the fully qualified formula names and follow the stable or explicitly
opted-in current matched-stack procedure in the
[`container-compose` install guide](https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md).
Branch, tag, package, and tap behavior is defined only in the
[`container-compose` release guide](https://github.com/stephenlclarke/container-compose/blob/main/BRANCHES.md).

The builder shim is not a Homebrew formula. `container` selects an immutable
builder image through `BUILDER_SHIM_REPOSITORY` and `BUILDER_SHIM_VERSION`; the
current packaged value is reported by `container system version` and tracked in
the canonical
[`STATUS.md`](https://github.com/stephenlclarke/container-compose/blob/main/STATUS.md).
