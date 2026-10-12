/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (c) 2026 the container project authors.
 *
 * Standalone libext2fs consumer. The parent owns lifecycle exclusion, a private
 * staged image and atomic commit. This process never opens a host pathname.
 */
#include <ext2fs/ext2fs.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "copy_sandbox.h"

enum { IMAGE_FD = 3, SOURCE_FD = 4, UNSUPPORTED = 3, PATH_LIMIT = 4096 };

struct request {
    const char *destination;
    const char *basename;
    unsigned int mode, uid, gid;
    int parents, ownership;
};

static int number(const char *text, unsigned int *value) {
    char *end;
    unsigned long parsed;
    if (!text[0] || text[0] == '-' || text[0] == '+') return 0;
    errno = 0;
    parsed = strtoul(text, &end, 10);
    if (errno || *end || parsed > UINT32_MAX) return 0;
    *value = (unsigned int)parsed;
    return 1;
}

static int parse(int argc, char **argv, struct request *request) {
    unsigned int parents, ownership;
    if (argc != 9 || strcmp(argv[1], "--protocol=1") ||
        !number(argv[4], &request->mode) || request->mode > 0777 ||
        !number(argv[5], &request->uid) || !number(argv[6], &request->gid) ||
        !number(argv[7], &parents) || parents > 1 ||
        !number(argv[8], &ownership) || ownership > 1) return 0;
    request->destination = argv[2];
    request->basename = argv[3];
    request->parents = (int)parents;
    request->ownership = (int)ownership;
    return 1;
}

/* Path-dependent links, ACL inheritance and special inode semantics stay on
 * the guest path until their differential parity is established. Any partial
 * work is confined to a disposable staged image, never the live rootfs. */
static int simple_inode(ext2_filsys fs, ext2_ino_t ino, const struct ext2_inode *inode) {
    /* The SDK formatter uses filesystem-block units for i_blocks, including
     * directories. libext2fs understands this flag; it is not an inode policy. */
    if ((inode->i_flags & ~(EXT4_EXTENTS_FL | EXT4_HUGE_FILE_FL)) || inode->i_file_acl ||
        inode->osd2.linux2.l_i_file_acl_high || (inode->i_mode & 07000)) return 0;
    /* ACLs and capabilities may be inline, with no external xattr block. */
    struct ext2_xattr_handle *attributes = NULL;
    size_t count = 0;
    errcode_t error = ext2fs_xattrs_open(fs, ino, &attributes);
    if (!error) error = ext2fs_xattrs_read(attributes);
    if (!error) error = ext2fs_xattrs_count(attributes, &count);
    if (attributes) {
        errcode_t close_error = ext2fs_xattrs_close(&attributes);
        if (!error) error = close_error;
    }
    return !error && !count;
}

static errcode_t lookup(ext2_filsys fs, ext2_ino_t parent, const char *name,
                        ext2_ino_t *ino, struct ext2_inode *inode) {
    errcode_t error = ext2fs_lookup(fs, parent, name, (int)strlen(name), NULL, ino);
    if (!error) error = ext2fs_read_inode(fs, *ino, inode);
    return error;
}

static errcode_t changed_directory(ext2_filsys fs, ext2_ino_t ino) {
    struct ext2_inode inode;
    errcode_t error = ext2fs_read_inode(fs, ino, &inode);
    if (error) return error;
    inode.i_mtime = inode.i_ctime = (unsigned int)time(NULL);
    return ext2fs_write_inode(fs, ino, &inode);
}

static errcode_t make_directory(ext2_filsys fs, ext2_ino_t parent,
                                const char *name, ext2_ino_t *ino) {
    struct ext2_inode inode;
    errcode_t error = ext2fs_mkdir(fs, parent, 0, name);
    if (error == EXT2_ET_DIR_NO_SPACE) {
        error = ext2fs_expand_dir(fs, parent);
        if (!error) error = ext2fs_mkdir(fs, parent, 0, name);
    }
    if (!error) error = lookup(fs, parent, name, ino, &inode);
    if (error) return error;
    inode.i_mode = LINUX_S_IFDIR | 0755;
    inode.i_uid = inode.i_gid = 0;
    inode.osd2.linux2.l_i_uid_high = inode.osd2.linux2.l_i_gid_high = 0;
    error = ext2fs_write_inode(fs, *ino, &inode);
    return error ? error : changed_directory(fs, parent);
}

static int valid_component(const char *name) {
    size_t length = strlen(name);
    return length > 0 && length <= EXT2_NAME_LEN && !strchr(name, '/') &&
        strcmp(name, ".") && strcmp(name, "..");
}

/* Resolve only ordinary components. Repeated separators are harmless, but
 * dot/dot-dot are not lexically collapsed across possibly symbolic links. */
static errcode_t destination(ext2_filsys fs, const struct request *request,
                             ext2_ino_t *parent, char **name,
                             ext2_ino_t *existing) {
    char path[PATH_LIMIT + 1], *parts[PATH_LIMIT / 2 + 1], *save = NULL;
    size_t count = 0, length = strlen(request->destination);
    struct ext2_inode inode;
    ext2_ino_t current = EXT2_ROOT_INO, next = 0;
    errcode_t error;
    if (!length || length > PATH_LIMIT || !valid_component(request->basename))
        return EXT2_ET_OP_NOT_SUPPORTED;
    memcpy(path, request->destination, length + 1);
    for (char *part = strtok_r(path, "/", &save); part;
         part = strtok_r(NULL, "/", &save)) {
        if (!valid_component(part) || count == PATH_LIMIT / 2)
            return EXT2_ET_OP_NOT_SUPPORTED;
        parts[count++] = part;
    }
    for (size_t index = 0; index < count; index++) {
        error = ext2fs_read_inode(fs, current, &inode);
        if (error) return error;
        if (!LINUX_S_ISDIR(inode.i_mode) || !simple_inode(fs, current, &inode))
            return EXT2_ET_OP_NOT_SUPPORTED;
        error = lookup(fs, current, parts[index], &next, &inode);
        if (index + 1 == count && error == EXT2_ET_FILE_NOT_FOUND) {
            if (request->destination[length - 1] == '/')
                return EXT2_ET_OP_NOT_SUPPORTED;
            *parent = current;
            *name = strdup(parts[index]);
            *existing = 0;
            return *name ? 0 : ENOMEM;
        }
        if (error == EXT2_ET_FILE_NOT_FOUND && request->parents) {
            error = make_directory(fs, current, parts[index], &next);
            if (!error) error = ext2fs_read_inode(fs, next, &inode);
        }
        if (error) return error;
        if (!simple_inode(fs, next, &inode)) return EXT2_ET_OP_NOT_SUPPORTED;
        if (index + 1 == count && LINUX_S_ISREG(inode.i_mode)) {
            if (request->destination[length - 1] == '/')
                return EXT2_ET_OP_NOT_SUPPORTED;
            *parent = current;
            *name = strdup(parts[index]);
            *existing = next;
            return *name ? 0 : ENOMEM;
        }
        if (!LINUX_S_ISDIR(inode.i_mode)) return EXT2_ET_OP_NOT_SUPPORTED;
        current = next;
    }
    error = ext2fs_read_inode(fs, current, &inode);
    if (error) return error;
    if (!simple_inode(fs, current, &inode)) return EXT2_ET_OP_NOT_SUPPORTED;
    *parent = current;
    *name = strdup(request->basename);
    if (!*name) return ENOMEM;
    error = lookup(fs, current, *name, existing, &inode);
    if (error == EXT2_ET_FILE_NOT_FOUND) { *existing = 0; return 0; }
    if (!error && (!LINUX_S_ISREG(inode.i_mode) || !simple_inode(fs, *existing, &inode)))
        return EXT2_ET_OP_NOT_SUPPORTED;
    return error;
}

static errcode_t create_file(ext2_filsys fs, ext2_ino_t parent,
                             const char *name, ext2_ino_t *ino) {
    struct ext2_inode inode = {0};
    ext2_extent_handle_t extent = NULL;
    errcode_t error = ext2fs_new_inode(fs, parent, LINUX_S_IFREG | 0600, NULL, ino);
    if (error) return error;
    inode.i_mode = LINUX_S_IFREG | 0600;
    inode.i_links_count = 1;
    inode.i_atime = inode.i_ctime = inode.i_mtime = (unsigned int)time(NULL);
    error = ext2fs_extent_open2(fs, *ino, &inode, &extent);
    if (extent) ext2fs_extent_free(extent);
    if (!error) error = ext2fs_write_new_inode(fs, *ino, &inode);
    if (error) return error;
    ext2fs_inode_alloc_stats2(fs, *ino, 1, 0);
    error = ext2fs_link(fs, parent, name, *ino, EXT2_FT_REG_FILE);
    if (error == EXT2_ET_DIR_NO_SPACE) {
        error = ext2fs_expand_dir(fs, parent);
        if (!error) error = ext2fs_link(fs, parent, name, *ino, EXT2_FT_REG_FILE);
    }
    return error ? error : changed_directory(fs, parent);
}

static int unchanged_source(const struct stat *before, const struct stat *after) {
    return before->st_dev == after->st_dev && before->st_ino == after->st_ino &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

static errcode_t transfer(ext2_filsys fs, ext2_ino_t ino,
                          const struct request *request, off_t size) {
    ext2_file_t file = NULL;
    struct ext2_inode inode;
    char buffer[65536];
    errcode_t error = ext2fs_file_open(fs, ino, EXT2_FILE_WRITE, &file);
    if (!error) error = ext2fs_file_set_size2(file, 0);
    for (off_t offset = 0; !error && offset < size;) {
        size_t wanted = (size - offset < (off_t)sizeof(buffer))
            ? (size_t)(size - offset) : sizeof(buffer);
        ssize_t count = pread(SOURCE_FD, buffer, wanted, offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { error = count ? errno : EIO; break; }
        unsigned int written = 0;
        error = ext2fs_file_write(file, buffer, (unsigned int)count, &written);
        if (!error && written != (unsigned int)count) error = EIO;
        offset += count;
    }
    if (file) {
        errcode_t close_error = ext2fs_file_close(file);
        if (!error) error = close_error;
    }
    if (!error) error = ext2fs_read_inode(fs, ino, &inode);
    if (error) return error;
    inode.i_mode = LINUX_S_IFREG | request->mode;
    if (request->ownership) {
        inode.i_uid = request->uid & 0xffff;
        inode.i_gid = request->gid & 0xffff;
        inode.osd2.linux2.l_i_uid_high = request->uid >> 16;
        inode.osd2.linux2.l_i_gid_high = request->gid >> 16;
    }
    inode.i_mtime = inode.i_ctime = (unsigned int)time(NULL);
    return ext2fs_write_inode(fs, ino, &inode);
}

int main(int argc, char **argv) {
    struct request request = {0};
    struct stat image, source, after;
    ext2_filsys fs = NULL;
    ext2_ino_t parent = 0, ino = 0;
    char *name = NULL;
    errcode_t error;
    int result = UNSUPPORTED;
    if (!parse(argc, argv, &request)) return 2;
    if (fstat(IMAGE_FD, &image) || fstat(SOURCE_FD, &source) ||
        !S_ISREG(image.st_mode) || !S_ISREG(source.st_mode) || source.st_size < 0 ||
        image.st_uid != geteuid() || image.st_nlink != 1 || (image.st_mode & 077) ||
        (image.st_dev == source.st_dev && image.st_ino == source.st_ino) ||
        (fcntl(IMAGE_FD, F_GETFL) & O_ACCMODE) != O_RDWR ||
        (fcntl(SOURCE_FD, F_GETFL) & O_ACCMODE) != O_RDONLY) return 2;
    /* Time bounds are also enforced by the parent, which must reap this child
     * before releasing the container lifecycle fence or discarding staging. */
    struct rlimit cpu = {30, 30};
    if (setrlimit(RLIMIT_CPU, &cpu)) return 2;
    if (container_copy_sandbox(IMAGE_FD, SOURCE_FD)) return UNSUPPORTED;
    error = ext2fs_open("3", EXT2_FLAG_RW | EXT2_FLAG_64BITS, 0, 0, unixfd_io_manager, &fs);
    if (error) goto cleanup;
    if (!(fs->super->s_state & EXT2_VALID_FS) || (fs->super->s_state & EXT2_ERROR_FS) ||
        ext2fs_has_feature_journal_needs_recovery(fs->super) ||
        ext2fs_has_feature_journal(fs->super) || fs->super->s_last_orphan ||
        !ext2fs_has_feature_extents(fs->super)) goto cleanup;
    error = ext2fs_read_bitmaps(fs);
    if (error) goto cleanup;
    error = destination(fs, &request, &parent, &name, &ino);
    if (error) goto cleanup;
    if (!ino) error = create_file(fs, parent, name, &ino);
    if (!error) error = transfer(fs, ino, &request, source.st_size);
    if (error || fstat(SOURCE_FD, &after) || !unchanged_source(&source, &after)) goto cleanup;
    error = ext2fs_flush(fs);
    if (!error) error = ext2fs_close_free(&fs);
    if (!error && !fsync(IMAGE_FD)) result = 0;
cleanup:
    if (fs) ext2fs_free(fs);
    free(name);
    return result;
}
