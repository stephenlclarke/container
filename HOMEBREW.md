# Homebrew Formulae

This fork publishes prebuilt Homebrew assets through
`stephenlclarke/homebrew-tap`. The branch policy is documented in
[`container-compose/BRANCHES.md`](https://github.com/stephenlclarke/container-compose/blob/main/BRANCHES.md).

Homebrew formulae install prebuilt release-quality package assets. The stable
formula is built from a validated bare semantic source tag on `main`, with the
matching `containerization` fork pin recorded by this repository. Main
validation packages prove the branch can build but do not update the stable
formula.

The builder shim is not installed as a Homebrew formula. `container` pins the
immutable `ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.8` image
used by build workflows.

Use the fully qualified formula name so Homebrew does not resolve
Homebrew/core's `container` formula first.

## Stable Install

```sh
brew tap stephenlclarke/tap
brew install stephenlclarke/tap/container
brew services start container
container system version
```

## Branch and Release Policy

Do not create branch-derived formula lanes for new work. The active stack
policy is:

- `main` is the current, releasable integration branch.
- Bare semantic tags on `main` publish stable assets and update
  `stephenlclarke/homebrew-tap` when the tap token is configured.
- Main validation packages are CI artifacts and are not the stable Homebrew
  install formula.

Keep detailed branch, tag, and Homebrew formula rules in
[`container-compose/BRANCHES.md`](https://github.com/stephenlclarke/container-compose/blob/main/BRANCHES.md)
so the four-repository stack has one source of truth.
