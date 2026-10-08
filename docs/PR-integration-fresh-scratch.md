<!-- markdownlint-disable MD013 -->

# fix(test): isolate runtime integration scratch per invocation

## Type of change

Bug fix with regression tests and documentation.

## Motivation and context

A fixed temporary scratch directory could outlive its ownership marker and block every later integration run. Claiming or deleting that unmarked directory would weaken the ownership check.

## Implementation and compatibility

Every run claims a fresh short marked sibling before coverage instrumentation or service startup and records its path in the integration result. A collision or symlink remains a closed failure. The old scratch tree is preserved. Original fixtures, inventory, assertions, coverage and timeouts are unchanged; previously prepared compiled products remain bound to their actual producer revision.

## Testing

All eleven runtime-integration harness tests pass. The regression preserves an existing unmarked scratch tree across two new workspace allocations, verifies both ownership markers and short paths, and rejects an occupied generated path. The original failed full attempt and successful host/binary restoration are retained. A new full integration run is required; dependency source and artifact checks already passed and are not rerun for this harness-only change.
