#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <Security/Authorization.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef ENOATTR
#ifdef ENODATA
#define ENOATTR ENODATA
#else
#define ENOATTR ENOENT
#endif
#endif

extern void *edp_rw_open(const char *cipher_path, const char *key_hex);
extern void *edp_rw_open_device(const char *raw_path, const char *vid_hex,
                                const char *pid_hex,
                                unsigned long long device_size_bytes,
                                const unsigned char *password_bytes,
                                unsigned long long password_length,
                                uint32_t partition_type);
extern void *edp_rw_open_device_fd(int raw_fd, const char *vid_hex,
                                   const char *pid_hex,
                                   unsigned long long device_size_bytes,
                                   const unsigned char *password_bytes,
                                   unsigned long long password_length,
                                   uint32_t partition_type);
extern unsigned long long edp_rw_size(void *handle);
extern long long edp_rw_read(void *handle, unsigned long long offset, void *buffer,
                             unsigned long long requested_length);
extern long long edp_rw_write(void *handle, unsigned long long offset,
                              const void *buffer,
                              unsigned long long requested_length);
extern int32_t edp_rw_sync(void *handle);
extern void edp_rw_close(void *handle);
extern void *edp_ro_open_device_fd(int raw_fd, const char *vid_hex,
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
static int read_only_mode = 0;

static void secure_zero(void *buffer, size_t length) {
    volatile unsigned char *bytes = (volatile unsigned char *)buffer;
    while (length-- > 0) *bytes++ = 0;
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
        do { result = read(fd, &extra, 1); } while (result < 0 && errno == EINTR);
        secure_zero(&extra, sizeof(extra));
        if (result != 0) return -1;
    }
    if (length == 0) return -1;
    *length_out = length;
    return 0;
}

static int receive_fd(int socket_fd) {
    char payload = 0;
    struct iovec iov = { .iov_base = &payload, .iov_len = sizeof(payload) };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);
    ssize_t received = recvmsg(socket_fd, &msg, 0);
    if (received <= 0) return -1;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
         cmsg != NULL;
         cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
            int fd = -1;
            memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
            return fd;
        }
    }
    return -1;
}

static int authopen_fd(const char *path, int open_flags,
                       const AuthorizationExternalForm *external_form) {
    int sockets[2];
    int stdin_pipe[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return -1;
    if (pipe(stdin_pipe) != 0) {
        close(sockets[0]); close(sockets[1]);
        return -1;
    }
    pid_t child = fork();
    if (child < 0) {
        close(sockets[0]); close(sockets[1]);
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        return -1;
    }
    if (child == 0) {
        close(sockets[0]);
        close(stdin_pipe[1]);
        if (dup2(stdin_pipe[0], STDIN_FILENO) < 0 ||
            dup2(sockets[1], STDOUT_FILENO) < 0) {
            _exit(126);
        }
        close(stdin_pipe[0]);
        close(sockets[1]);
        char flags_buf[32];
        snprintf(flags_buf, sizeof(flags_buf), "%d", open_flags);
        execl("/usr/libexec/authopen", "authopen",
              "-stdoutpipe", "-extauth", "-o", flags_buf, path, (char *)NULL);
        _exit(127);
    }
    close(sockets[1]);
    close(stdin_pipe[0]);
    const unsigned char *cursor = (const unsigned char *)external_form;
    size_t remaining = sizeof(*external_form);
    while (remaining > 0) {
        ssize_t n = write(stdin_pipe[1], cursor, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        cursor += n;
        remaining -= (size_t)n;
    }
    close(stdin_pipe[1]);
    int fd = receive_fd(sockets[0]);
    close(sockets[0]);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (fd < 0) {
        if (WIFEXITED(status)) {
            fprintf(stderr, "EDP_AUTHOPEN_EXIT_STATUS=%d\n", WEXITSTATUS(status));
        }
        return -1;
    }
    return fd;
}

static void print_usage(const char *program) {
    fprintf(stderr,
            "usage:\n"
            "  %s <cipher.img> <32-hex-key> <mountpoint>\n"
            "  %s --device <raw-device> <vid> <pid> <device-size> "
            "<partition-type> <password-fd> <mountpoint>\n"
            "  %s --device-auth <raw-device> <vid> <pid> <device-size> "
            "<partition-type> <control-fd> <mountpoint>\n"
            "  %s --device-auth-readonly <raw-device> <vid> <pid> <device-size> "
            "<partition-type> <control-fd> <mountpoint>\n",
            program, program, program, program);
}

static int m_getattr(const char *path, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_uid = getuid(); st->st_gid = getgid();
    st->st_atime = 1; st->st_mtime = 1; st->st_ctime = 1;
    st->st_blksize = 4096;
    if (strcmp(path, "/") == 0) {
        st->st_ino = 1; st->st_mode = S_IFDIR | 0755; st->st_nlink = 2;
        return 0;
    }
    if (strcmp(path, volume_path) == 0) {
        st->st_ino = 2; st->st_mode = S_IFREG | (read_only_mode ? 0444 : 0666); st->st_nlink = 1;
        st->st_size = (off_t)volume_size;
        st->st_blocks = (blkcnt_t)((volume_size + 511) / 512);
        return 0;
    }
    return -ENOENT;
}

static int m_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                     off_t offset, struct fuse_file_info *fi) {
    (void)offset; (void)fi;
    if (strcmp(path, "/") != 0) return -ENOENT;
    filler(buf, ".", NULL, 0); filler(buf, "..", NULL, 0);
    filler(buf, "volume.raw", NULL, 0);
    return 0;
}

static int m_access(const char *path, int mask) {
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    if (read_only_mode && (mask & W_OK)) return -EROFS;
    return 0;
}

static int m_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (read_only_mode && (fi->flags & O_ACCMODE) != O_RDONLY) return -EROFS;
    fi->fh = 42;
    return 0;
}

static int m_read(const char *path, char *buf, size_t size, off_t offset,
                  struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (offset < 0) return -EINVAL;
    long long result = read_only_mode
        ? edp_ro_read(block_handle, (uint64_t)offset, buf, size)
        : edp_rw_read(block_handle, (uint64_t)offset, buf, size);
    if (result < 0) return (int)result;
    if ((unsigned long long)result > (unsigned long long)INT_MAX) return -EIO;
    return (int)result;
}

static int m_write(const char *path, const char *buf, size_t size, off_t offset,
                   struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (read_only_mode) return -EROFS;
    if (offset < 0) return -EINVAL;
    long long result = edp_rw_write(block_handle, (uint64_t)offset, buf, size);
    if (result < 0) return (int)result;
    if ((unsigned long long)result > (unsigned long long)INT_MAX) return -EIO;
    return (int)result;
}

static int m_flush(const char *path, struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (read_only_mode) return 0;
    return (int)edp_rw_sync(block_handle);
}

static int m_fsync(const char *path, int datasync, struct fuse_file_info *fi) {
    (void)datasync;
    return m_flush(path, fi);
}

static int m_release(const char *path, struct fuse_file_info *fi) {
    return m_flush(path, fi);
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
    (void)list; (void)size;
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    return 0;
}

static int m_statfs(const char *path, struct statvfs *st) {
    (void)path;
    memset(st, 0, sizeof(*st));
    st->f_bsize = 4096; st->f_frsize = 4096;
    st->f_blocks = volume_size / 4096;
    st->f_bfree = st->f_bavail = 0;
    st->f_files = 2; st->f_ffree = 0; st->f_namemax = 255;
    return 0;
}

static void *m_init(struct fuse_conn_info *conn) {
    (void)conn;
    fprintf(stderr, "EDP_FUSE_READY\n");
    fflush(stderr);
    return NULL;
}

static struct fuse_operations ops = {
    .getattr = m_getattr, .readdir = m_readdir, .access = m_access,
    .open = m_open, .read = m_read, .write = m_write,
    .release = m_release, .flush = m_flush, .fsync = m_fsync,
    .getxattr = m_getxattr, .listxattr = m_listxattr, .statfs = m_statfs,
    .init = m_init,
};

int main(int argc, char **argv) {
    const char *mountpoint = NULL;
    if (argc == 9 && (strcmp(argv[1], "--device") == 0 ||
                      strcmp(argv[1], "--device-auth") == 0 ||
                      strcmp(argv[1], "--device-auth-readonly") == 0)) {
        uint64_t device_size = 0;
        uint32_t partition_type = 0;
        int password_fd = -1;
        if (parse_u64(argv[5], &device_size) != 0 || device_size == 0 ||
            parse_u32(argv[6], &partition_type) != 0 ||
            (partition_type != 2 && partition_type != 4) ||
            parse_fd(argv[7], &password_fd) != 0) {
            print_usage(argv[0]); return 64;
        }

        unsigned char control[sizeof(AuthorizationExternalForm) + 4096];
        size_t control_length = 0;
        if (read_password_fd(password_fd, control, sizeof(control),
                             &control_length) != 0) {
            close(password_fd); secure_zero(control, sizeof(control));
            fprintf(stderr, "EDP_FUSE_CONTROL_FD_READ_FAILED\n"); return 65;
        }
        close(password_fd);

        unsigned char *password = control;
        size_t password_length = control_length;
        int authorized_raw_fd = -1;
        if (strcmp(argv[1], "--device-auth") == 0 ||
            strcmp(argv[1], "--device-auth-readonly") == 0) {
            if (control_length <= sizeof(AuthorizationExternalForm)) {
                secure_zero(control, sizeof(control));
                fprintf(stderr, "EDP_FUSE_AUTH_CONTROL_TOO_SHORT\n"); return 65;
            }
            AuthorizationExternalForm external_form;
            memcpy(&external_form, control, sizeof(external_form));
            password = control + sizeof(external_form);
            password_length = control_length - sizeof(external_form);
            read_only_mode = strcmp(argv[1], "--device-auth-readonly") == 0;
            int raw_flags = (read_only_mode ? O_RDONLY : O_RDWR) | O_CLOEXEC;
            authorized_raw_fd = authopen_fd(argv[2], raw_flags, &external_form);
            secure_zero(&external_form, sizeof(external_form));
            if (authorized_raw_fd < 0) {
                secure_zero(control, sizeof(control));
                fprintf(stderr, "EDP_FUSE_AUTHOPEN_FAILED\n"); return 65;
            }
            block_handle = read_only_mode
                ? edp_ro_open_device_fd(
                    authorized_raw_fd, argv[3], argv[4], device_size, password,
                    password_length, partition_type
                )
                : edp_rw_open_device_fd(
                    authorized_raw_fd, argv[3], argv[4], device_size, password,
                    password_length, partition_type
                );
            close(authorized_raw_fd);
        } else {
            block_handle = edp_rw_open_device(
                argv[2], argv[3], argv[4], device_size, password,
                password_length, partition_type
            );
        }
        secure_zero(control, sizeof(control));
        if (!block_handle) {
            fprintf(stderr, "EDP_FUSE_BRIDGE_OPEN_DEVICE_FAILED\n"); return 65;
        }
        mountpoint = argv[8];
    } else if (argc == 4) {
        block_handle = edp_rw_open(argv[1], argv[2]);
        if (!block_handle) {
            fprintf(stderr, "EDP_FUSE_BRIDGE_OPEN_FAILED\n"); return 65;
        }
        mountpoint = argv[3];
    } else {
        print_usage(argv[0]); return 64;
    }

    volume_size = read_only_mode ? edp_ro_size(block_handle) : edp_rw_size(block_handle);
    if (volume_size == 0) {
        if (read_only_mode) {
            edp_ro_close(block_handle);
        } else {
            edp_rw_close(block_handle);
        }
        block_handle = NULL;
        fprintf(stderr, "EDP_FUSE_BRIDGE_INVALID_SIZE\n"); return 66;
    }

    char options[176];
    snprintf(options, sizeof(options),
             "backend=fskit,big_writes,noatime,uid=%u,gid=%u",
             getuid(), getgid());
    char *fuse_argv[] = {
        argv[0], "-f", "-o", options, (char *)mountpoint, NULL,
    };
    fprintf(stderr, "EDP_FUSE_BLOCK_SIZE=%llu\n",
            (unsigned long long)volume_size);
    int rc = fuse_main(5, fuse_argv, &ops, NULL);
    if (read_only_mode) {
        edp_ro_close(block_handle);
    } else {
        (void)edp_rw_sync(block_handle);
        edp_rw_close(block_handle);
    }
    block_handle = NULL;
    return rc;
}
