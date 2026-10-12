// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the container project authors.
#include "COfflineCopyProcess.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <libproc.h>
#include <sys/resource.h>
#include <spawn.h>
#include <stdint.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int reap(pid_t child, int *status, int flags) {
    pid_t result;
    do { result = waitpid(child, status, flags); } while (result < 0 && errno == EINTR);
    return (int)result;
}

static int64_t monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    return now.tv_sec;
}

int cec_run(const char *executable, const char *const arguments[],
            int image_fd, int source_fd, unsigned int timeout_seconds, int *status) {
    if (!executable || !arguments || !status || !timeout_seconds || timeout_seconds > 300)
        return EINVAL;
    int input = fcntl(image_fd, F_DUPFD_CLOEXEC, 10);
    if (input < 0) return errno;
    int source = fcntl(source_fd, F_DUPFD_CLOEXEC, 10);
    if (source < 0) { int error = errno; close(input); return error; }
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) { close(input); close(source); return error; }
    posix_spawnattr_t attributes;
    int attribute_error = posix_spawnattr_init(&attributes);
    if (attribute_error) { error = attribute_error; goto cleanup_actions; }
    error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, input, 3);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, source, 4);
    if (!error) error = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    if (!error) error = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    if (!error) error = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    char *const environment[] = {"LANG=C", "LC_ALL=C", NULL};
    pid_t child = 0;
    int64_t started = monotonic_seconds();
    if (!error && started < 0) error = errno;
    if (!error) error = posix_spawn(&child, executable, &actions, &attributes,
                                   (char *const *)arguments, environment);
    if (!error) {
        int child_status = 0;
        for (;;) {
            int observed = reap(child, &child_status, WNOHANG);
            if (observed == child) {
                *status = WIFEXITED(child_status) ? WEXITSTATUS(child_status) : 128;
                break;
            }
            if (observed < 0) { error = errno; break; }
            int64_t current = monotonic_seconds();
            // The child may parse guest-controlled metadata. Monitor charged
            // memory as well as resident pages; this host rejects the desired
            // finite RLIMIT_DATA and RLIMIT_AS bounds. Overshoot between samples
            // is possible, so this is a watchdog rather than a hard VM quota.
            struct rusage_info_v0 usage = {0};
            int sampled = proc_pid_rusage(child, RUSAGE_INFO_V0, (rusage_info_t *)&usage);
            if (sampled && errno == ESRCH) continue; // Exit raced with sampling.
            if (sampled || usage.ri_phys_footprint > CEC_MEMORY_LIMIT ||
                usage.ri_resident_size > CEC_MEMORY_LIMIT) {
                error = sampled ? errno : ENOMEM;
                (void)kill(child, SIGKILL);
                (void)reap(child, &child_status, 0);
                break;
            }
            if (current < 0 || current - started >= timeout_seconds) {
                error = current < 0 ? errno : ETIMEDOUT;
                (void)kill(child, SIGKILL);
                (void)reap(child, &child_status, 0);
                break;
            }
            struct timespec interval = {0, 1000000};
            (void)nanosleep(&interval, NULL);
        }
    }
    posix_spawnattr_destroy(&attributes);
cleanup_actions:
    posix_spawn_file_actions_destroy(&actions);
    close(input);
    close(source);
    return error;
}
