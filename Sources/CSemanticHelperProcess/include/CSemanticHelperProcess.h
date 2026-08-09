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

#ifndef C_SEMANTIC_HELPER_PROCESS_H
#define C_SEMANTIC_HELPER_PROCESS_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Starts one helper with one endpoint of an anonymous socketpair inherited as
/// descriptor 3. The parent endpoint is nonblocking and close-on-exec.
int csh_spawn(
    const char *executable_path,
    int inherit_environment,
    pid_t *child_pid,
    int *parent_fd
);

ssize_t csh_read(int fd, void *buffer, size_t count);
ssize_t csh_write(int fd, const void *buffer, size_t count);

/// Returns 1 when ready, 0 on timeout, and -1 on error.
int csh_poll_readable(int fd, int timeout_milliseconds);
int csh_poll_writable(int fd, int timeout_milliseconds);

int csh_close(int fd);
int csh_signal(pid_t pid, int signal_number);

/// Returns the waitpid result. A zero result means the child is still alive.
pid_t csh_wait_nohang(pid_t pid, int *status);
pid_t csh_wait(pid_t pid, int *status);

int csh_errno(void);
int csh_signal_terminate(void);
int csh_signal_kill(void);
int csh_error_interrupted(void);
int csh_error_would_block(void);

#ifdef __cplusplus
}
#endif

#endif
