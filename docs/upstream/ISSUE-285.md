# Issue 285: observe cleanup cancellation at every suspension point

## Problem

The hosted pull-request gate for the debug-symbol packaging repair exposed a
scheduling race in `ImageCleanupTests.cleanupFailureCancelsSibling`. The
unfinished content-cleanup task reached a two-task barrier before installing
the cancellation observer around its later sleep. If snapshot cleanup failed
while the content task was suspended at that barrier, structured concurrency
cancelled the task correctly but the test never recorded the cancellation and
timed out after one second.

## Resolution

Install the task-cancellation handler before the content task reaches its first
suspension point. The test retains the entry barrier, the deliberately long
unfinished operation, and the bounded cancellation countdown, so it still
proves that both cleanups started and a failing child cancelled its sibling.

Related issue: [#285](https://github.com/stephenlclarke/container/issues/285).
Validated in pull request
[#284](https://github.com/stephenlclarke/container/pull/284).
