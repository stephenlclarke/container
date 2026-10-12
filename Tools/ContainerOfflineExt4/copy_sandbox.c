/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (c) 2026 the container project authors. */
#include "copy_sandbox.h"

#include <fcntl.h>
#include <sandbox.h>
#include <stdio.h>
#include <sys/param.h>

/* SBPL literals must never contain request-controlled syntax. Unsupported
 * control/non-ASCII host path spellings select the existing guest transfer. */
static int descriptor_literal(int fd, char *output, size_t capacity) {
    char path[MAXPATHLEN];
    if (fcntl(fd, F_GETPATH, path)) return -1;
    size_t offset = 0;
    for (const unsigned char *character = (const unsigned char *)path; *character; character++) {
        if (*character < 32 || *character > 126 || offset + 2 >= capacity) return -1;
        if (*character == '\\' || *character == '"') output[offset++] = '\\';
        output[offset++] = (char)*character;
    }
    output[offset] = '\0';
    return 0;
}

static int apply_profile(const char *profile) {
    char *error = NULL;
    /* Failure is always fatal to this helper operation. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int result = sandbox_init(profile, 0, &error);
    if (error) sandbox_free_error(error);
#pragma clang diagnostic pop
    return result;
}

int container_copy_probe(void) {
    return apply_profile("(version 1)(deny default)(allow file-read-metadata)");
}

int container_copy_sandbox(int image_fd, int source_fd) {
    char image[2 * MAXPATHLEN], source[2 * MAXPATHLEN], profile[4 * MAXPATHLEN + 512];
    if (descriptor_literal(image_fd, image, sizeof(image)) ||
        descriptor_literal(source_fd, source, sizeof(source))) return -1;
    int length = snprintf(profile, sizeof(profile),
        "(version 1)(deny default)(allow file-read-metadata)"
        "(allow file-read-data (literal \"%s\"))"
        "(allow file-read-data file-write-data (literal \"%s\"))"
        "(allow file-read-data file-write-data (literal \"/dev/null\"))", source, image);
    if (length < 0 || (size_t)length >= sizeof(profile)) return -1;
    /* macOS provides this process-level API, but marks it deprecated. Failure
     * is a hard eligibility boundary: no unsandboxed filesystem parser runs.
     * A future replacement must pass the same negative confinement tests. */
    return apply_profile(profile);
}
