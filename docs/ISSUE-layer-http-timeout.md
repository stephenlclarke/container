<!-- markdownlint-disable MD013 -->

# HTTP-client layer timeout fixture and duplicate invocations

## Problem

The full HTTP-client host suite reports exactly two failures: the synchronous and asynchronous connect-timeout fixtures receive a TCP reset from backlog overflow on macOS rather than a timed-out connection. The normal suite skips those explicit host cases. Changing the destination address and selecting POSIX event loops independently confirmed that backlog overflow is not a reliable timeout fixture on this host. Original failures remain in retained evidence.

The per-layer check also starts separate Bazel build and test invocations, although the test invocation can build both targets.

## Required behavior

Retain both real HTTP-client deadline assertions, the asynchronous duration bound, and owned loopback resources. Avoid assumptions about kernel backlog overflow. Combine product and suite targets in one invocation; retain every independent layer result and cache rather than restarting the entire graph.
