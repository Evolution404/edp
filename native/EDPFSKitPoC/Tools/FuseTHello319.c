#define FUSE_USE_VERSION 319

#include <errno.h>
#include <fcntl.h>
#include <fuse.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static const char kHelloPath[] = "/hello.txt";
static const char kHelloText[] = "EDP FUSE-T FSKit bridge smoke\n";

static int hello_getattr(const char *path, struct stat *st, struct fuse_file_info *fi) {
    (void)fi;
    memset(st, 0, sizeof(*st));

    if (strcmp(path, "/") == 0) {
        st->st_mode = S_IFDIR | 0555;
        st->st_nlink = 2;
        return 0;
    }

    if (strcmp(path, kHelloPath) == 0) {
        st->st_mode = S_IFREG | 0444;
        st->st_nlink = 1;
        st->st_size = (off_t)(sizeof(kHelloText) - 1);
        return 0;
    }

    return -ENOENT;
}

static int hello_readdir(const char *path,
                         void *buf,
                         fuse_fill_dir_t filler,
                         off_t offset,
                         struct fuse_file_info *fi,
                         enum fuse_readdir_flags flags) {
    (void)offset;
    (void)fi;
    (void)flags;

    if (strcmp(path, "/") != 0) {
        return -ENOENT;
    }

    filler(buf, ".", NULL, 0, 0);
    filler(buf, "..", NULL, 0, 0);
    filler(buf, "hello.txt", NULL, 0, 0);
    return 0;
}

static int hello_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, kHelloPath) != 0) {
        return -ENOENT;
    }
    if ((fi->flags & O_ACCMODE) != O_RDONLY) {
        return -EROFS;
    }
    return 0;
}

static int hello_read(const char *path,
                      char *buf,
                      size_t size,
                      off_t offset,
                      struct fuse_file_info *fi) {
    (void)fi;

    if (strcmp(path, kHelloPath) != 0) {
        return -ENOENT;
    }

    const size_t length = sizeof(kHelloText) - 1;
    if (offset < 0 || (uint64_t)offset >= length) {
        return 0;
    }

    size_t remaining = length - (size_t)offset;
    if (size > remaining) {
        size = remaining;
    }
    memcpy(buf, kHelloText + offset, size);
    return (int)size;
}

static const struct fuse_operations kOperations = {
    .getattr = hello_getattr,
    .open = hello_open,
    .read = hello_read,
    .readdir = hello_readdir,
};

int main(int argc, char **argv) {
    return fuse_main(argc, argv, &kOperations, NULL);
}
