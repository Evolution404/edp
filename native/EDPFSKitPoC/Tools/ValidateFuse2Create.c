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
static int target_exists = 1;
static unsigned char target_data[8192] = "old-content\n";
static size_t target_size = sizeof("old-content\n") - 1;
static int support_rename_swap = 0;

#ifndef RENAME_SWAP
#define RENAME_SWAP 0x00000002
#endif
#ifndef RENAME_EXCL
#define RENAME_EXCL 0x00000004
#endif

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
    if (split_file_path(path, &name) != 0) return -ENOENT;
    if (target_exists && strcmp(name, "target.txt") == 0) {
        st->st_mode = S_IFREG | 0644;
        st->st_nlink = 1;
        st->st_size = (off_t)target_size;
        return 0;
    }
    if (!file_exists || strcmp(name, file_name) != 0) return -ENOENT;
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
    if (target_exists) filler(buf, "target.txt", NULL, 0);
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
    if (split_file_path(path, &name) != 0) return -ENOENT;
    if (!(target_exists && strcmp(name, "target.txt") == 0) &&
        (!file_exists || strcmp(name, file_name) != 0)) {
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
    if (split_file_path(path, &name) != 0) return -ENOENT;
    const unsigned char *data = file_data;
    size_t data_size = file_size;
    if (target_exists && strcmp(name, "target.txt") == 0) {
        data = target_data;
        data_size = target_size;
    } else if (!file_exists || strcmp(name, file_name) != 0) {
        return -ENOENT;
    }
    if (offset < 0 || (size_t)offset >= data_size) return 0;
    size_t available = data_size - (size_t)offset;
    if (size > available) size = available;
    memcpy(buf, data + offset, size);
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

#ifdef __APPLE__
static int m_setattr_x(const char *path, struct setattr_x *attr) {
    fprintf(stderr, "FUSE2_SETATTR_X path=%s valid=0x%x size=%lld\n",
            path, (unsigned int)attr->valid, (long long)attr->size);
    if (SETATTR_WANTS_SIZE(attr)) return m_truncate(path, attr->size);
    return 0;
}

static int m_fsetattr_x(const char *path, struct setattr_x *attr,
                        struct fuse_file_info *fi) {
    (void)fi;
    fprintf(stderr, "FUSE2_FSETATTR_X path=%s valid=0x%x size=%lld\n",
            path, (unsigned int)attr->valid, (long long)attr->size);
    return m_setattr_x(path, attr);
}

static int m_getxtimes(const char *path, struct timespec *bkuptime,
                       struct timespec *crtime) {
    struct stat st;
    int rc = m_getattr(path, &st);
    if (rc != 0) return rc;
    *bkuptime = st.st_mtimespec;
    *crtime = st.st_birthtimespec;
    fprintf(stderr, "FUSE2_GETXTIMES path=%s\n", path);
    return 0;
}
#endif

static int m_unlink(const char *path) {
    const char *name = NULL;
    if (split_file_path(path, &name) != 0) return -ENOENT;
    if (target_exists && strcmp(name, "target.txt") == 0) {
        target_exists = 0;
        target_size = 0;
        fprintf(stderr, "FUSE2_UNLINK path=%s\n", path);
        return 0;
    }
    if (!file_exists || strcmp(name, file_name) != 0) return -ENOENT;
    file_exists = 0;
    file_name[0] = '\0';
    file_size = 0;
    fprintf(stderr, "FUSE2_UNLINK path=%s\n", path);
    return 0;
}

static int replace_target(const char *old_path, const char *new_path) {
    const char *old_name = NULL;
    const char *new_name = NULL;
    if (split_file_path(old_path, &old_name) != 0 || split_file_path(new_path, &new_name) != 0) return -ENOENT;
    if (!file_exists || strcmp(old_name, file_name) != 0) return -ENOENT;
    if (strcmp(new_name, "target.txt") != 0) return -EOPNOTSUPP;
    memcpy(target_data, file_data, file_size);
    target_size = file_size;
    target_exists = 1;
    file_exists = 0;
    file_name[0] = '\0';
    file_size = 0;
    return 0;
}

static int m_rename(const char *old_path, const char *new_path) {
    fprintf(stderr, "FUSE2_RENAME old=%s new=%s\n", old_path, new_path);
    return replace_target(old_path, new_path);
}

#ifdef __APPLE__
static int m_renamex(const char *old_path, const char *new_path, unsigned int flags) {
    fprintf(stderr, "FUSE2_RENAMEX old=%s new=%s flags=0x%x support_swap=%d\n",
            old_path, new_path, flags, support_rename_swap);
    if (flags & RENAME_SWAP) {
        const char *old_name = NULL;
        const char *new_name = NULL;
        if (!support_rename_swap) return -EOPNOTSUPP;
        if (split_file_path(old_path, &old_name) != 0 || split_file_path(new_path, &new_name) != 0) return -ENOENT;
        if (!file_exists || !target_exists || strcmp(old_name, file_name) != 0 || strcmp(new_name, "target.txt") != 0) return -ENOENT;
        unsigned char tmp[sizeof(file_data)];
        memcpy(tmp, file_data, sizeof(file_data));
        memcpy(file_data, target_data, sizeof(file_data));
        memcpy(target_data, tmp, sizeof(file_data));
        size_t tmp_size = file_size;
        file_size = target_size;
        target_size = tmp_size;
        return 0;
    }
    if (flags & ~RENAME_EXCL) return -EINVAL;
    if ((flags & RENAME_EXCL) && target_exists) return -EEXIST;
    return replace_target(old_path, new_path);
}

static void *m_init(struct fuse_conn_info *conn) {
#ifdef FUSE_CAP_RENAME_SWAP
    fprintf(stderr, "FUSE2_INIT capable=0x%x want_before=0x%x rename_swap_cap=0x%x\n",
            conn->capable, conn->want, FUSE_CAP_RENAME_SWAP);
    if (support_rename_swap) {
        conn->want |= FUSE_CAP_RENAME_SWAP;
    } else {
        conn->want &= ~FUSE_CAP_RENAME_SWAP;
    }
    fprintf(stderr, "FUSE2_INIT want_after=0x%x support_swap=%d\n",
            conn->want, support_rename_swap);
#endif
    return NULL;
}
#endif

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
#ifdef __APPLE__
    .init = m_init,
#endif
    .getattr = m_getattr,
    .readdir = m_readdir,
    .create = m_create,
    .open = m_open,
    .read = m_read,
    .write = m_write,
    .truncate = m_truncate,
    .ftruncate = m_ftruncate,
    .fgetattr = m_fgetattr,
#ifdef __APPLE__
    .setattr_x = m_setattr_x,
    .fsetattr_x = m_fsetattr_x,
    .getxtimes = m_getxtimes,
    .renamex = m_renamex,
#endif
    .rename = m_rename,
    .unlink = m_unlink,
    .flush = m_flush,
    .release = m_release,
};

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--rename") == 0) {
        errno = 0;
        int rc = rename(argv[2], argv[3]);
        int saved_errno = errno;
        printf("RENAME_CLIENT_RC=%d\n", rc);
        printf("RENAME_CLIENT_ERRNO=%d\n", saved_errno);
        printf("RENAME_CLIENT_ERROR=%s\n", saved_errno ? strerror(saved_errno) : "none");
        return rc == 0 ? 0 : 1;
    }
    if (argc != 2) {
        fprintf(stderr, "usage: %s <mountpoint> | --rename <old> <new>\n", argv[0]);
        return 64;
    }
    const char *swap_env = getenv("EDP_FUSE2_SUPPORT_RENAME_SWAP");
    support_rename_swap = swap_env && strcmp(swap_env, "1") == 0;
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
