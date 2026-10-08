<!-- markdownlint-disable MD013 -->

# Fixed integration scratch becomes unusable after its marker expires

## Motivation and context

The full Container integration attempt failed before running its fixtures because `/private/tmp/cfb-501/fork/integration` existed without its original ownership marker. The harness correctly refused to claim it and restored the signed binaries, services and Colima. Re-entering the same command cannot repair that condition.

## Required behavior

Preserve unknown prior data and allocate fresh marked scratch per invocation. Keep paths short for socket fixtures, reject an unexpected collision, and check scratch admission before instrumenting binaries or starting services. Retain the original failed attempt and rerun only integration with its new input.
