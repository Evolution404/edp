#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#ifndef ENOATTR
#ifdef ENODATA
#define ENOATTR ENODATA
#else
#define ENOATTR ENOENT
#endif
#endif

extern void *edp_ro_open(const char *cipher_path, const char *key_hex);
extern void *edp_ro_open_device(const char *raw_path, const char *vid_hex,
                                const char *pid_hex,
                                unsigned long long device_size_bytes,
                                const unsigned char *password_bytes,
                                unsigned long long password_length,
                                uint32_t partition_type);
extern unsigned long long edp_ro_size(void *handle);
extern long long edp_ro_read(void *handle, unsigned long long offset, void *buffer,
                             unsigned long long requested_length);
extern void edp_ro_close(void *handle);

static const char *volume_path = "/volume.raw";
static void *block_handle = NULL;
static uint64_t volume_size = 0;

static void secure_zero(void *buffer, size_t length) {
    volatile unsigned char *bytes = (volatile unsigned char *)buffer;
    while (length-- > 0) {
        *bytes++ = 0;
    }
}

static int parse_u64(const char *text, uint64_t *value) {
    if (!text || !*text || !value) return -1;
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(text, &end, 10);
    if (errno != 0 || !end || *end != '\0') return -1;
    *value = (uint64_t)parsed;
    return 0;
}

static int parse_u32(const char *text, uint32_t *value) {
    uint64_t parsed = 0;
    if (parse_u64(text, &parsed) != 0 || parsed > UINT32_MAX) return -1;
    *value = (uint32_t)parsed;
    return 0;
}

static int parse_fd(const char *text, int *value) {
    uint64_t parsed = 0;
    if (parse_u64(text, &parsed) != 0 || parsed > INT_MAX) return -1;
    *value = (int)parsed;
    return 0;
}

static int read_password_fd(int fd, unsigned char *buffer, size_t capacity,
                            size_t *length_out) {
    if (fd < 0 || !buffer || capacity == 0 || !length_out) return -1;

    size_t length = 0;
    while (length < capacity) {
        ssize_t result = read(fd, buffer + length, capacity - length);
        if (result < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (result == 0) break;
        length += (size_t)result;
    }

    if (length == capacity) {
        unsigned char extra = 0;
        ssize_t result;
        do {
            result = read(fd, &extra, 1);
        } while (result < 0 && errno == EINTR);
        if (result != 0) {
            secure_zero(&extra, sizeof(extra));
            return -1;
        }
    }

    if (length == 0) return -1;
    *length_out = length;
    return 0;
}

static void print_usage(const char *program) {
    fprintf(stderr,
            "usage:\n"
            "  %s <cipher.img> <32-hex-key> <mountpoint>\n"
            "  %s --device <raw-device> <vid> <pid> <device-size> "
            "<partition-type> <password-fd> <mountpoint>\n",
            program, program);
}

static int m_getattr(const char *path, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_uid = getuid();
    st->st_gid = getgid();
    st->st_atime = 1;
    st->st_mtime = 1;
    st->st_ctime = 1;
    st->st_blksize = 4096;

    if (strcmp(path, "/") == 0) {
        st->st_ino = 1;
        st->st_mode = S_IFDIR | 0555;
        st->st_nlink = 2;
        return 0;
    }
    if (strcmp(path, volume_path) == 0) {
        st->st_ino = 2;
        st->st_mode = S_IFREG | 0444;
        st->st_nlink = 1;
        st->st_size = (off_t)volume_size;
        st->st_blocks = (blkcnt_t)((volume_size + 511) / 512);
        return 0;
    }
    return -ENOENT;
}

static int m_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                     off_t offset, struct fuse_file_info *fi) {
    (void)offset;
    (void)fi;
    if (strcmp(path, "/") != 0) return -ENOENT;
    filler(buf, ".", NULL, 0);
    filler(buf, "..", NULL, 0);
    filler(buf, "volume.raw", NULL, 0);
    return 0;
}

static int m_access(const char *path, int mask) {
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    if (mask & W_OK) return -EROFS;
    return 0;
}

static int m_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if ((fi->flags & O_ACCMODE) != O_RDONLY) return -EROFS;
    fi->fh = 42;
    return 0;
}

static int m_read(const char *path, char *buf, size_t size, off_t offset,
                  struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (offset < 0) return -EINVAL;

    long long result = edp_ro_read(
        block_handle,
        (unsigned long long)offset,
        buf,
        (unsigned long long)size
    );
    if (result < 0) return (int)result;
    if ((unsigned long long)result > (unsigned long long)INT_MAX) return -EIO;
    return (int)result;
}

static int m_release(const char *path, struct fuse_file_info *fi) {
    (void)path;
    (void)fi;
    return 0;
}

#ifdef __APPLE__
static int m_getxattr(const char *path, const char *name, char *value,
                      size_t size, uint32_t position) {
    (void)value; (void)size; (void)position;
#else
static int m_getxattr(const char *path, const char *name, char *value,
                      size_t size) {
    (void)value; (void)size;
#endif
    (void)name;
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    return -ENOATTR;
}

static int m_listxattr(const char *path, char *list, size_t size) {
    (void)list;
    (void)size;
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    return 0;
}

static int m_statfs(const char *path, struct statvfs *st) {
    (void)path;
    memset(st, 0, sizeof(*st));
    st->f_bsize = 4096;
    st->f_frsize = 4096;
    st->f_blocks = volume_size / 4096;
    st->f_bfree = 0;
    st->f_bavail = 0;
    st->f_files = 2;
    st->f_ffree = 0;
    st->f_namemax = 255;
    return 0;
}

static struct fuse_operations ops = {
    .getattr = m_getattr,
    .readdir = m_readdir,
    .access = m_access,
    .open = m_open,
    .read = m_read,
    .release = m_release,
    .getxattr = m_getxattr,
    .listxattr = m_listxattr,
    .statfs = m_statfs,
};

int main(int argc, char **argv) {
    const char *mountpoint = NULL;

    if (argc == 9 && strcmp(argv[1], "--device") == 0) {
        uint64_t device_size = 0;
        uint32_t partition_type = 0;
        int password_fd = -1;
        if (parse_u64(argv[5], &device_size) != 0 || device_size == 0 ||
            parse_u32(argv[6], &partition_type) != 0 ||
            (partition_type != 2 && partition_type != 4) ||
            parse_fd(argv[7], &password_fd) != 0) {
            print_usage(argv[0]);
            return 64;
        }

        unsigned char password[4096];
        size_t password_length = 0;
        if (read_password_fd(password_fd, password, sizeof(password),
                             &password_length) != 0) {
            close(password_fd);
            secure_zero(password, sizeof(password));
            fprintf(stderr, "EDP_FUSE_PASSWORD_FD_READ_FAILED\n");
            return 65;
        }
        close(password_fd);

        block_handle = edp_ro_open_device(
            argv[2], argv[3], argv[4],
            (unsigned long long)device_size,
            password,
            (unsigned long long)password_length,
            partition_type
        );
        secure_zero(password, sizeof(password));
        if (!block_handle) {
            fprintf(stderr, "EDP_FUSE_BRIDGE_OPEN_DEVICE_FAILED\n");
            return 65;
        }
        mountpoint = argv[8];
    } else if (argc == 4) {
        block_handle = edp_ro_open(argv[1], argv[2]);
        if (!block_handle) {
            fprintf(stderr, "EDP_FUSE_BRIDGE_OPEN_FAILED\n");
            return 65;
        }
        mountpoint = argv[3];
    } else {
        print_usage(argv[0]);
        return 64;
    }

    volume_size = (uint64_t)edp_ro_size(block_handle);
    if (volume_size == 0) {
        edp_ro_close(block_handle);
        block_handle = NULL;
        fprintf(stderr, "EDP_FUSE_BRIDGE_INVALID_SIZE\n");
        return 66;
    }

    char options[128];
    snprintf(options, sizeof(options), "backend=fskit,uid=%u,gid=%u", getuid(), getgid());
    char *fuse_argv[] = {
        argv[0],
        "-f",
        "-o",
        options,
        (char *)mountpoint,
        NULL,
    };

    fprintf(stderr, "EDP_FUSE_BLOCK_SIZE=%llu\n", (unsigned long long)volume_size);
    int rc = fuse_main(5, fuse_argv, &ops, NULL);
    edp_ro_close(block_handle);
    block_handle = NULL;
    return rc;
}
