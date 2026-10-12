/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (c) 2026 the container project authors. */
#include "copy_sandbox.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 2 || (argc == 3 && !strcmp(argv[2], "probe")));
    int probe = argc == 3;
    char image_path[4096], source_path[4096], outside_path[4096], new_path[4096];
    assert(mkdir(argv[1], 0700) == 0);
    snprintf(image_path, sizeof(image_path), "%s/image", argv[1]);
    snprintf(source_path, sizeof(source_path), "%s/source", argv[1]);
    snprintf(outside_path, sizeof(outside_path), "%s/outside", argv[1]);
    snprintf(new_path, sizeof(new_path), "%s/new", argv[1]);
    int image = open(image_path, O_CREAT | O_EXCL | O_RDWR, 0600);
    int source = open(source_path, O_CREAT | O_EXCL | O_RDWR, 0600);
    int outside = open(outside_path, O_CREAT | O_EXCL | O_RDWR, 0600);
    assert(image >= 0 && source >= 0 && outside >= 0);
    assert(write(source, "s", 1) == 1);
    close(source);
    source = open(source_path, O_RDONLY);
    close(outside);
    char byte;
    if (probe) {
        close(image);
        close(source);
        assert(container_copy_probe() == 0);
        assert(open(image_path, O_RDWR) == -1 && (errno == EPERM || errno == EACCES));
        assert(open(source_path, O_RDONLY) == -1 && (errno == EPERM || errno == EACCES));
    } else {
        assert(container_copy_sandbox(image, source) == 0);
        assert(pwrite(image, "i", 1, 0) == 1);
        assert(pread(source, &byte, 1, 0) == 1 && byte == 's');
    }
    assert(open("/etc/passwd", O_RDONLY) == -1 && (errno == EPERM || errno == EACCES));
    assert(open(outside_path, O_RDONLY) == -1 && (errno == EPERM || errno == EACCES));
    assert(open(new_path, O_CREAT | O_WRONLY, 0600) == -1 && (errno == EPERM || errno == EACCES));
    assert(open(source_path, O_WRONLY) == -1 && (errno == EPERM || errno == EACCES));
    int network = socket(AF_INET, SOCK_STREAM, 0);
    if (network >= 0) {
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(9);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(connect(network, (struct sockaddr *)&address, sizeof(address)) == -1 && errno == EPERM);
        close(network);
    } else {
        assert(errno == EPERM);
    }
    pid_t child;
    char *const arguments[] = {"/usr/bin/true", NULL};
    char *const environment[] = {NULL};
    int spawned = posix_spawn(&child, arguments[0], NULL, NULL, arguments, environment);
    if (!spawned) { int status; (void)waitpid(child, &status, 0); }
    assert(spawned == EPERM || spawned == EACCES);
    if (!probe) {
        close(image);
        close(source);
    }
    return 0;
}
