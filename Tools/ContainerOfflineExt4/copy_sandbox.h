/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (c) 2026 the container project authors. */
#ifndef CONTAINER_COPY_SANDBOX_H
#define CONTAINER_COPY_SANDBOX_H

/* Must succeed before parsing guest-controlled filesystem metadata. */
int container_copy_sandbox(int image_fd, int source_fd);

/* Startup preflight allows no file data, process launch or network access. */
int container_copy_probe(void);

#endif
