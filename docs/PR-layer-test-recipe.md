<!-- markdownlint-disable MD013 -->

# fix(build): admit the exact host timeout fixture recipe transition

## Type of change

Bug fix with regression tests and documentation.

## Motivation and context

The complete HTTP-client suite now passes, but a test-only fixture hash prevented reuse of unchanged published native libraries. The compatibility policy recognizes one fixed before/after fixture pair; it does not ignore test patches generally or change any published asset.

## Implementation and compatibility

The policy retains the original verifier pair admission and accepts the exact fixture transition either independently or alongside that pair. All other input keys and SHA-256 values remain exact. Consumer receipts record the distinct producer/current recipes, policy hash and changed files. Lower pins, archive hashes, toolchain checks and compiler-consumption proofs remain mandatory.

## Testing

Eight focused policy tests pass, including rejection of unknown and reversed patch edits, production drift, partial verifier drift, inventory changes and policy substitution. The complete native importer and build-tool suite are checked next. The original failed import remains in retained evidence. Current source tests passed independently; historical qualification is not relabeled as a new release.
