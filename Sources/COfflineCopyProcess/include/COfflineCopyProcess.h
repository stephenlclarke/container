// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the container project authors.
#ifndef C_OFFLINE_COPY_PROCESS_H
#define C_OFFLINE_COPY_PROCESS_H

#define CEC_MEMORY_LIMIT (256ULL * 1024 * 1024)

/* Run the standalone helper with only staged-image/source descriptors 3/4.
 * Return an errno value for launch/wait/timeout/memory-watchdog errors, otherwise zero and the
 * child's exit code in status. Every successfully spawned child is reaped. */
int cec_run(const char *executable, const char *const arguments[],
            int image_fd, int source_fd, unsigned int timeout_seconds, int *status);

/* Launch only the no-data startup probe, retaining the same watchdog and reap. */
int cec_probe(const char *executable, unsigned int timeout_seconds, int *status);

#endif
