# Homebrew Branch Formula

This fork carries a Homebrew formula for testing the `develop` and `main`
branches before changes are accepted upstream by Apple. It mirrors the
Homebrew/core `container` formula, but resolves `container` from
`stephenlclarke/container` so the forked lanes can be installed explicitly.

Use the fully qualified formula name so Homebrew does not resolve
Homebrew/core's `container` formula first.

## Develop

```sh
brew tap stephenlclarke/container https://github.com/stephenlclarke/container
git -C "$(brew --repo stephenlclarke/container)" checkout develop
brew install --build-from-source --HEAD stephenlclarke/container/container
brew services start container
```

## Main

```sh
brew tap stephenlclarke/container https://github.com/stephenlclarke/container
git -C "$(brew --repo stephenlclarke/container)" checkout main
brew reinstall --build-from-source --HEAD stephenlclarke/container/container
brew services restart container
```
