# Container IDs exceed the DNS label limit

## Problem

Candidate validation accepts IDs up to 255 bytes. Native `--name` becomes the
container ID and that ID is used as a network hostname. The captured test run
shows that a 64-character ID is accepted when it should be rejected.

## Expected behavior

Native container IDs must be at most 63 ASCII characters. Preserve the existing
character rules. Docker API names remain separate in `dockerName` and are not
changed by this issue.

## Acceptance

- A 63-character name is valid; a 64-character name is invalid.
- Existing valid-name and invalid-character checks remain unchanged.
- CLI help and command reference state the limit.
- Do not weaken tests or alter the captured benchmark evidence.

See `PR-container-id-name-length.md` for the implementation and validation.
