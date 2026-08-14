//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#include "CSemanticHelperProcess.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

enum { CSH_CHILD_DESCRIPTOR = 3 };

static int csh_has_prefix(const char *value, const char *prefix) {
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

/// Preserve the authority environment needed by Application Default
/// Credentials while rejecting dynamic-loader injection controls.
static void csh_free_environment(char **environment) {
    if (environment == NULL) {
        return;
    }
    for (char **entry = environment; *entry != NULL; entry++) {
        free(*entry);
    }
    free(environment);
}

static int csh_copy_safe_inherited_environment(
    const uint8_t *environment_block,
    size_t environment_block_length,
    char ***environment_out
) {
    *environment_out = NULL;
    if (environment_block_length > 0 && environment_block == NULL) {
        return EINVAL;
    }
    size_t capacity = 16;
    char **result = calloc(capacity, sizeof(char *));
    if (result == NULL) {
        return ENOMEM;
    }
    size_t index = 0;
    size_t offset = 0;
    while (offset < environment_block_length) {
        const char *entry = (const char *)(environment_block + offset);
        size_t remaining = environment_block_length - offset;
        const char *terminator = memchr(entry, '\0', remaining);
        if (terminator == NULL || terminator == entry) {
            csh_free_environment(result);
            return EINVAL;
        }
        if (
            !csh_has_prefix(entry, "DYLD_")
            && !csh_has_prefix(entry, "LD_")
        ) {
            if (index + 1 >= capacity) {
                if (capacity > SIZE_MAX / 2 / sizeof(*result)) {
                    csh_free_environment(result);
                    return ENOMEM;
                }
                capacity *= 2;
                char **resized = realloc(result, capacity * sizeof(*result));
                if (resized == NULL) {
                    csh_free_environment(result);
                    return ENOMEM;
                }
                result = resized;
            }
            result[index] = strdup(entry);
            if (result[index] == NULL) {
                csh_free_environment(result);
                return ENOMEM;
            }
            index++;
            result[index] = NULL;
        }
        offset += (size_t)(terminator - entry) + 1;
    }
    *environment_out = result;
    return 0;
}

static int csh_poll(int fd, short events, int timeout_milliseconds) {
    struct pollfd descriptor = {
        .fd = fd,
        .events = events,
        .revents = 0,
    };
    int result;
    do {
        result = poll(&descriptor, 1, timeout_milliseconds);
    } while (result < 0 && errno == EINTR);
    if (result <= 0) {
        return result;
    }
    if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
        errno = EPIPE;
        return -1;
    }
    return (descriptor.revents & events) != 0 ? 1 : 0;
}

int csh_spawn(
    const char *executable_path,
    int inherit_environment,
    const uint8_t *inherited_environment_block,
    size_t inherited_environment_block_length,
    pid_t *child_pid,
    int *parent_fd
) {
    if (executable_path == NULL || child_pid == NULL || parent_fd == NULL) {
        return EINVAL;
    }

    int sockets[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        return errno;
    }

    int no_sigpipe = 1;
    if (
        setsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &no_sigpipe,
            sizeof(no_sigpipe)
        ) != 0
    ) {
        int saved_errno = errno;
        close(sockets[0]);
        close(sockets[1]);
        return saved_errno;
    }

    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        close(sockets[0]);
        close(sockets[1]);
        return result;
    }

    result = posix_spawn_file_actions_addclose(&actions, sockets[0]);
    if (result == 0 && sockets[1] != CSH_CHILD_DESCRIPTOR) {
        result = posix_spawn_file_actions_adddup2(
            &actions,
            sockets[1],
            CSH_CHILD_DESCRIPTOR
        );
    }
    if (result == 0 && sockets[1] != CSH_CHILD_DESCRIPTOR) {
        result = posix_spawn_file_actions_addclose(&actions, sockets[1]);
    }

    posix_spawnattr_t attributes;
    int attribute_result = posix_spawnattr_init(&attributes);
    if (result == 0) {
        result = attribute_result;
    }
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    if (result == 0) {
        result = posix_spawnattr_setflags(
            &attributes,
            POSIX_SPAWN_CLOEXEC_DEFAULT
        );
    }
#endif

    char *const arguments[] = {
        (char *)executable_path,
        (char *)"--fd=3",
        NULL,
    };
    char *const restricted_environment[] = {
        (char *)"LANG=C",
        (char *)"LC_ALL=C",
        (char *)"PATH=/usr/bin:/bin",
        NULL,
    };
    char **inherited_environment = NULL;
    char *const *environment = restricted_environment;
    if (inherit_environment != 0) {
        int environment_result = csh_copy_safe_inherited_environment(
            inherited_environment_block,
            inherited_environment_block_length,
            &inherited_environment
        );
        if (environment_result != 0) {
            if (attribute_result == 0) {
                posix_spawnattr_destroy(&attributes);
            }
            posix_spawn_file_actions_destroy(&actions);
            close(sockets[0]);
            close(sockets[1]);
            return environment_result;
        }
        environment = inherited_environment;
    }
    pid_t pid = 0;
    if (result == 0) {
        result = posix_spawn(
            &pid,
            executable_path,
            &actions,
            &attributes,
            arguments,
            environment
        );
    }

    csh_free_environment(inherited_environment);

    if (attribute_result == 0) {
        posix_spawnattr_destroy(&attributes);
    }
    posix_spawn_file_actions_destroy(&actions);
    close(sockets[1]);

    if (result != 0) {
        close(sockets[0]);
        return result;
    }

    int descriptor_flags = fcntl(sockets[0], F_GETFD);
    int status_flags = fcntl(sockets[0], F_GETFL);
    if (
        descriptor_flags < 0
        || status_flags < 0
        || fcntl(sockets[0], F_SETFD, descriptor_flags | FD_CLOEXEC) < 0
        || fcntl(sockets[0], F_SETFL, status_flags | O_NONBLOCK) < 0
    ) {
        int saved_errno = errno;
        close(sockets[0]);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return saved_errno;
    }

    *child_pid = pid;
    *parent_fd = sockets[0];
    return 0;
}

ssize_t csh_read(int fd, void *buffer, size_t count) {
    return read(fd, buffer, count);
}

ssize_t csh_write(int fd, const void *buffer, size_t count) {
    return write(fd, buffer, count);
}

int csh_poll_readable(int fd, int timeout_milliseconds) {
    return csh_poll(fd, POLLIN, timeout_milliseconds);
}

int csh_poll_writable(int fd, int timeout_milliseconds) {
    return csh_poll(fd, POLLOUT, timeout_milliseconds);
}

int csh_close(int fd) {
    return close(fd);
}

int csh_signal(pid_t pid, int signal_number) {
    return kill(pid, signal_number);
}

pid_t csh_wait_nohang(pid_t pid, int *status) {
    return waitpid(pid, status, WNOHANG);
}

pid_t csh_wait(pid_t pid, int *status) {
    pid_t result;
    do {
        result = waitpid(pid, status, 0);
    } while (result < 0 && errno == EINTR);
    return result;
}

int csh_errno(void) {
    return errno;
}

int csh_signal_terminate(void) {
    return SIGTERM;
}

int csh_signal_kill(void) {
    return SIGKILL;
}

int csh_error_interrupted(void) {
    return EINTR;
}

int csh_error_would_block(void) {
    return EAGAIN;
}
