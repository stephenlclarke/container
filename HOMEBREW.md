# Homebrew Formulae

This fork publishes prebuilt Homebrew assets through
`stephenlclarke/homebrew-tap`. The branch policy is documented in
[`container-compose/BRANCHES.md`](https://github.com/stephenlclarke/container-compose/blob/main/BRANCHES.md).

Homebrew formulae install prebuilt release-quality package assets. The main formula is built from `container` `main` with `containerization` `main`; the release formula is built from `container` `release` with `containerization` `release`. The builder shim is not installed as a formula; `container` pins the immutable `ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.6` image used by build workflows.

Use the fully qualified formula name so Homebrew does not resolve
Homebrew/core's `container` formula first.

## Main

```sh
brew tap stephenlclarke/tap
brew install stephenlclarke/tap/container
brew services start container
container system version
```

## Release Branches

The `release` branch publishes `container-release`. Tagged release branch copies
publish branch-derived formula names such as `container-release-v0-1-0`.

```sh
brew tap stephenlclarke/tap
brew install stephenlclarke/tap/container-release
brew services restart container-release
container system version
```
