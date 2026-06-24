# Branch Guide

This fork keeps two public environments for `container-compose` testers and
contributors.

- `main`: stable lane for people trying the app/plugin without chasing active
  runtime development. Move it only after a validation pass, and treat it as
  frozen between promoted snapshots.
- `develop`: development lane for day-to-day runtime integration testing. Move
  it freely as fork-backed runtime work lands.

Use matching branches in the plugin and runtime checkouts:

```sh
git -C ~/github/container-compose checkout main
git -C ~/github/container checkout main
```

```sh
git -C ~/github/container-compose checkout develop
git -C ~/github/container checkout develop
```

Fork-backed runtime changes should still be split into small Apple-facing
branches before opening pull requests against
[`apple/container`](https://github.com/apple/container). Keep one runtime
capability per PR where practical, with focused tests and no Compose-specific
policy in the runtime branch.
