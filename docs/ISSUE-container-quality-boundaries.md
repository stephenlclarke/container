<!-- markdownlint-disable MD013 -->

# Container quality boundaries block the candidate checkpoint

## Steps to reproduce

Analyze PR 292 at b29554345acb21e3b0dd05836a9471b592c020c8 with the retained unit and complete ten-layer integration coverage. Sonar reports 78.6% changed-code coverage against the unchanged 80% gate, plus 16 maintainability findings. The 436 passing integration cases do not cover enough of the offline copy writer.

## Problem and expected behavior

The child-process owner, copy options, builder startup options and machine configuration flags need clearer boundaries. Preserve existing public source compatibility, guest protocol paths, child ownership, memory and timeout checks, sandbox authentication, transactional readback and atomic publication. Fix the maintained code and exercise the missing behavior rather than changing gates or rebuilding historical references.

## Environment and linked work

This is the Container candidate in the retained local Container family performance/parity programme on macOS, consuming the published native SDK layer. See [PR 292](https://github.com/stephenlclarke/container/pull/292) and [the implementation handoff](PR-container-quality-boundaries.md). The original failed analysis and successful integration evidence remain retained. Apple issue 735 remains open; its explicit Dockerfile size guard must remain in place.
