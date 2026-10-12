// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the container project authors.
#include "COfflineCopyProcess.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Darwin internally reaps a rejected spawn asynchronously, without returning
 * a child PID. Only this standalone test may inspect the complete child set. */
static void expect_failed_spawn_cleanup(void) {
    struct timespec deadline, now;
    assert(clock_gettime(CLOCK_MONOTONIC, &deadline) == 0);
    deadline.tv_sec += 1;
    for (;;) {
        int status = -1;
        pid_t child = waitpid(-1, &status, WNOHANG);
        if (child == -1 && errno == ECHILD) return;
        assert(child == 0 || (child == -1 && errno == EINTR));
        assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
        assert(now.tv_sec < deadline.tv_sec ||
               (now.tv_sec == deadline.tv_sec && now.tv_nsec < deadline.tv_nsec));
        struct timespec interval = {0, 1000000};
        (void)nanosleep(&interval, NULL);
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--probe") == 0) return 0;
    if (argc == 2 && strcmp(argv[1], "memory-child") == 0) {
        // Touch anonymous pages gradually so the watchdog is exercised without
        // creating an unbounded allocation or relying on allocator bookkeeping.
        const size_t size = CEC_MEMORY_LIMIT + 32 * 1024 * 1024;
        volatile char *memory = malloc(size);
        assert(memory);
        for (size_t offset = 0; offset < size; offset += 4096) {
            memory[offset] = 1;
            if (offset % (1024 * 1024) == 0) usleep(1000);
        }
        sleep(5);
        free((void *)memory);
        return 0;
    }
    int image = open("/dev/null", O_RDWR | O_CLOEXEC);
    int source = open("/dev/null", O_RDONLY | O_CLOEXEC);
    assert(image >= 0 && source >= 0);
    int status = -1;
    const char *success[] = {"/usr/bin/true", NULL};
    assert(cec_probe(argv[0], 5, &status) == 0 && status == 0);
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    assert(cec_probe(NULL, 5, &status) == EINVAL);
    assert(cec_probe(argv[0], 0, &status) == EINVAL);
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    assert(cec_probe("/nonexistent-container-copy-helper", 5, &status) == ENOENT);
    expect_failed_spawn_cleanup();
    assert(cec_run(success[0], success, image, source, 5, &status) == 0 && status == 0);
    const char *failure[] = {"/usr/bin/false", NULL};
    assert(cec_run(failure[0], failure, image, source, 5, &status) == 0 && status == 1);
    const char *missing[] = {"/nonexistent-container-copy-helper", NULL};
    assert(cec_run(missing[0], missing, image, source, 5, &status) == ENOENT);
    const char *sleeping[] = {"/bin/sleep", "5", NULL};
    assert(cec_run(sleeping[0], sleeping, image, source, 1, &status) == ETIMEDOUT);
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    const char *memory[] = {argv[0], "memory-child", NULL};
    assert(cec_run(memory[0], memory, image, source, 5, &status) == ENOMEM);
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    assert(cec_run(success[0], success, -1, source, 5, &status) == EBADF);
    assert(cec_run(success[0], success, image, source, 0, &status) == EINVAL);
    assert(fcntl(image, F_GETFD) >= 0 && fcntl(source, F_GETFD) >= 0);
    close(image);
    close(source);
    return 0;
}
