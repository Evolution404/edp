#define FUSE_USE_VERSION 26
#define _FILE_OFFSET_BITS 64
#include <fuse.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int file_exists = 0;
static char file_name[256];
static unsigned char file_data[8192];
static size_t file_size = 0;

static int split_file_path(const char *path, const char **name) {
    if (!path || path[0] != '/' || path[1] == '\0' || strchr(path + 1, '/')) {
        return -ENOENT;
    }
    *name = path + 1;
    return 0;
}

static int m_getattr(const char *path, struct stat *st) {
    memset(st, 0, sizeof(*st));
    if (strcmp(path, "/") == 0) {
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 2;
        return 0;
    }
    const char *name = NULL;
    if (split_file_path(path, &name) != 0 || !file_exists || strcmp(name, file_name) != 0) {
        return -ENOENT;
    }
    st->st_mode = S_IFREG | 0644;
    st->st_nlink = 1;
    st->st_size = (off_t)file_size;
    return 0;
}

static int m_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                     off_t offset, struct fuse_file_info *fi) {
    (void)offset;
    (void)fi;
    if (strcmp(path, "/") != 0) return -ENOENT;
    filler(buf, ".", NULL, 0);
    filler(buf, "..", NULL, 0);
    if (file_exists) filler(buf, file_name, NULL, 0);
    return 0;
}

static int m_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
    (void)mode;
    const char *name = NULL;
    int rc = split_file_path(path, &name);
    if (rc != 0) return rc;
    if (strlen(name) >= sizeof(file_name)) return -ENAMETOOLONG;
    if (file_exists) return -EEXIST;
    strcpy(file_name, name);
    file_size = 0;
    file_exists = 1;
    fi->fh = 1;
    fprintf(stderr, "FUSE2_CREATE path=%s flags=0x%x\n", path, fi->flags);
    return 0;
}

static int m_open(const char *path, struct fuse_file_info *fi) {
    const char *name = NULL;
    if (split_file_path(path, &name) != 0 || !file_exists || strcmp(name, file_name) != 0) {
        return -ENOENT;
    }
    fi->fh = 1;
    fprintf(stderr, "FUSE2_OPEN path=%s flags=0x%x\n", path, fi->flags);
    return 0;
}

static int m_read(const char *path, char *buf, size_t size, off_t offset,
                  struct fuse_file_info *fi) {
    (void)fi;
    const char *name = NULL;
    if (split_file_path(path, &name) != 0 || !file_exists || strcmp(name, file_name) != 0) {
        return -ENOENT;
    }
    if (offset < 0 || (size_t)offset >= file_size) return 0;
    size_t available = file_size - (size_t)offset;
    if (size > available) size = available;
    memcpy(buf, file_data + offset, size);
    return (int)size;
}

static int m_write(const char *path, const char *buf, size_t size, off_t offset,
                   struct fuse_file_info *fi) {
    (void)fi;
    const char *name = NULL;
    if (split_file_path(path, &name) != 0 || !file_exists || strcmp(name, file_name) != 0) {
        return -ENOENT;
    }
    if (offset < 0 || (size_t)offset > sizeof(file_data) || size > sizeof(file_data) - (size_t)offset) {
        return -EFBIG;
    }
    memcpy(file_data + offset, buf, size);
    size_t end = (size_t)offset + size;
    if (end > file_size) file_size = end;
    fprintf(stderr, "FUSE2_WRITE path=%s offset=%lld size=%zu\n", path, (long long)offset, size);
    return (int)size;
}

static int m_truncate(const char *path, off_t size) {
    const char *name = NULL;
    if (split_file_path(path, &name) != 0 || !file_exists || strcmp(name, file_name) != 0) {
        return -ENOENT;
    }
    if (size < 0 || (size_t)size > sizeof(file_data)) return -EFBIG;
    if ((size_t)size > file_size) memset(file_data + file_size, 0, (size_t)size - file_size);
    file_size = (size_t)size;
    fprintf(stderr, "FUSE2_TRUNCATE path=%s size=%lld\n", path, (long long)size);
    return 0;
}

static int m_ftruncate(const char *path, off_t size, struct fuse_file_info *fi) {
    (void)fi;
    fprintf(stderr, "FUSE2_FTRUNCATE path=%s size=%lld\n", path, (long long)size);
    return m_truncate(path, size);
}

static int m_fgetattr(const char *path, struct stat *st, struct fuse_file_info *fi) {
    (void)fi;
    fprintf(stderr, "FUSE2_FGETATTR path=%s\n", path);
    return m_getattr(path, st);
}

static int m_unlink(const char *path) {
    const char *name = NULL;
    if (split_file_path(path, &name) != 0 || !file_exists || strcmp(name, file_name) != 0) {
        return -ENOENT;
    }
    file_exists = 0;
    file_name[0] = '\0';
    file_size = 0;
    return 0;
}

static int m_flush(const char *path, struct fuse_file_info *fi) {
    (void)path;
    (void)fi;
    return 0;
}

static int m_release(const char *path, struct fuse_file_info *fi) {
    (void)path;
    (void)fi;
    return 0;
}

static struct fuse_operations ops = {
    .getattr = m_getattr,
    .readdir = m_readdir,
    .create = m_create,
    .open = m_open,
    .read = m_read,
    .write = m_write,
    .truncate = m_truncate,
    .ftruncate = m_ftruncate,
    .fgetattr = m_fgetattr,
    .unlink = m_unlink,
    .flush = m_flush,
    .release = m_release,
};

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <mountpoint>\n", argv[0]);
        return 64;
    }
    char *fuse_argv[] = {
        argv[0],
        "-f",
        "-o",
        "backend=fskit,noatime,volname=EDPFUSE2CREATE",
        argv[1],
        NULL,
    };
    return fuse_main(5, fuse_argv, &ops, NULL);
}
