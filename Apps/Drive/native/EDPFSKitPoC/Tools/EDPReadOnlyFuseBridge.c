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

extern void *edp_ro_open(const char *cipher_path, const char *key_hex);
extern void *edp_ro_open_device(const char *raw_path, const char *vid_hex,
                                const char *pid_hex,
                                unsigned long long device_size_bytes,
                                const unsigned char *password_bytes,
                                unsigned long long password_length,
                                uint32_t partition_type);
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
static const char *probe_path = "/probe-readwrite-open.raw";
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

static int receive_fd(int socket_fd) {
    char payload = 0;
    struct iovec iov = { .iov_base = &payload, .iov_len = sizeof(payload) };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    ssize_t received;
    do { received = recvmsg(socket_fd, &message, 0); }
    while (received < 0 && errno == EINTR);
    if (received <= 0) return -1;
    for (struct cmsghdr *item = CMSG_FIRSTHDR(&message);
         item != NULL;
         item = CMSG_NXTHDR(&message, item)) {
        if (item->cmsg_level == SOL_SOCKET && item->cmsg_type == SCM_RIGHTS &&
            item->cmsg_len >= CMSG_LEN(sizeof(int))) {
            int fd = -1;
            memcpy(&fd, CMSG_DATA(item), sizeof(fd));
            return fd;
        }
    }
    return -1;
}

static int authopen_readonly_fd(const char *path,
                                const AuthorizationExternalForm *external_form) {
    int sockets[2];
    int input_pipe[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return -1;
    if (pipe(input_pipe) != 0) {
        close(sockets[0]); close(sockets[1]);
        return -1;
    }
    pid_t child = fork();
    if (child < 0) {
        close(sockets[0]); close(sockets[1]);
        close(input_pipe[0]); close(input_pipe[1]);
        return -1;
    }
    if (child == 0) {
        close(sockets[0]);
        close(input_pipe[1]);
        if (dup2(input_pipe[0], STDIN_FILENO) < 0 ||
            dup2(sockets[1], STDOUT_FILENO) < 0) _exit(126);
        close(input_pipe[0]);
        close(sockets[1]);
        char flags[32];
        snprintf(flags, sizeof(flags), "%d", O_RDONLY | O_CLOEXEC);
        execl("/usr/libexec/authopen", "authopen", "-stdoutpipe", "-extauth",
              "-o", flags, path, (char *)NULL);
        _exit(127);
    }
    close(sockets[1]);
    close(input_pipe[0]);
    const unsigned char *cursor = (const unsigned char *)external_form;
    size_t remaining = sizeof(*external_form);
    while (remaining > 0) {
        ssize_t written = write(input_pipe[1], cursor, remaining);
        if (written < 0) {
            if (errno == EINTR) continue;
            break;
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    close(input_pipe[1]);
    int fd = receive_fd(sockets[0]);
    close(sockets[0]);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    return fd;
}

static int interactive_readonly_fd(const char *path) {
    static const char prefix[] = "/dev/rdisk";
    if (strncmp(path, prefix, sizeof(prefix) - 1) != 0 ||
        path[sizeof(prefix) - 1] == '\0') return -1;
    for (const char *cursor = path + sizeof(prefix) - 1; *cursor != '\0'; ++cursor) {
        if (*cursor < '0' || *cursor > '9') return -1;
    }
    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                          kAuthorizationFlagDefaults, &authorization);
    if (status != errAuthorizationSuccess) return -1;
    AuthorizationItem item = { "system.privilege.admin", 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed |
                               kAuthorizationFlagExtendRights |
                               kAuthorizationFlagPreAuthorize;
    status = AuthorizationCopyRights(authorization, &rights,
                                     kAuthorizationEmptyEnvironment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        return -1;
    }
    AuthorizationExternalForm external_form;
    status = AuthorizationMakeExternalForm(authorization, &external_form);
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        return -1;
    }
    int fd = authopen_readonly_fd(path, &external_form);
    secure_zero(&external_form, sizeof(external_form));
    AuthorizationFree(authorization, kAuthorizationFlagDefaults);
    return fd;
}

static void print_usage(const char *program) {
    fprintf(stderr,
            "usage:\n"
            "  %s <cipher.img> <32-hex-key> <mountpoint>\n"
            "  %s --device <raw-device> <vid> <pid> <device-size> "
            "<partition-type> <password-fd> <mountpoint>\n"
            "  %s --device-authorize /dev/rdiskN <vid> <pid> <device-size> "
            "<partition-type> <password-fd> <mountpoint>\n"
            "  %s --device-authorize-fifo /dev/rdiskN <vid> <pid> <device-size> "
            "<partition-type> <password-fifo> <mountpoint>\n",
            program, program, program, program);
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
    if (strcmp(path, volume_path) == 0 || strcmp(path, probe_path) == 0) {
        int probe_alias = strcmp(path, probe_path) == 0;
        st->st_ino = probe_alias ? 3 : 2;
        /* The probe alias permits read-write access mode only for open. No write operation exists,
         * and the encrypted backing handle is always opened read-only. */
        st->st_mode = S_IFREG | (probe_alias ? 0666 : 0444);
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
    filler(buf, "probe-readwrite-open.raw", NULL, 0);
    return 0;
}

static int m_access(const char *path, int mask) {
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0 &&
        strcmp(path, probe_path) != 0) return -ENOENT;
    if ((mask & W_OK) && strcmp(path, probe_path) != 0) return -EROFS;
    return 0;
}

static int m_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, volume_path) == 0) {
        if ((fi->flags & O_ACCMODE) != O_RDONLY) return -EROFS;
    } else if (strcmp(path, probe_path) != 0) {
        return -ENOENT;
    }
    fi->fh = 42;
    return 0;
}

static int m_read(const char *path, char *buf, size_t size, off_t offset,
                  struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, volume_path) != 0 && strcmp(path, probe_path) != 0) return -ENOENT;
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
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0 &&
        strcmp(path, probe_path) != 0) return -ENOENT;
    return -ENOATTR;
}

static int m_listxattr(const char *path, char *list, size_t size) {
    (void)list;
    (void)size;
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0 &&
        strcmp(path, probe_path) != 0) return -ENOENT;
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
    st->f_files = 3;
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

    if (argc == 10 && strcmp(argv[1], "--device-authorize-fifo") == 0) {
        if (freopen(argv[9], "a", stdout) == NULL ||
            freopen(argv[9], "a", stderr) == NULL) return 65;
    }

    if ((argc == 9 || argc == 10) && (strcmp(argv[1], "--device") == 0 ||
                      strcmp(argv[1], "--device-authorize") == 0 ||
                      strcmp(argv[1], "--device-authorize-fifo") == 0)) {
        uint64_t device_size = 0;
        uint32_t partition_type = 0;
        int password_fd = -1;
        int fifo_mode = strcmp(argv[1], "--device-authorize-fifo") == 0;
        if ((fifo_mode && argc != 10) || (!fifo_mode && argc != 9)) {
            print_usage(argv[0]);
            return 64;
        }
        if (parse_u64(argv[5], &device_size) != 0 || device_size == 0 ||
            parse_u32(argv[6], &partition_type) != 0 ||
            (partition_type != 2 && partition_type != 4) ||
            (!fifo_mode && parse_fd(argv[7], &password_fd) != 0)) {
            print_usage(argv[0]);
            return 64;
        }
        if (fifo_mode) {
            password_fd = open(argv[7], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
            if (password_fd < 0) {
                fprintf(stderr, "EDP_FUSE_PASSWORD_FIFO_OPEN_FAILED\n");
                return 65;
            }
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

        if (strcmp(argv[1], "--device-authorize") == 0 || fifo_mode) {
            int raw_fd = interactive_readonly_fd(argv[2]);
            if (raw_fd < 0) {
                secure_zero(password, sizeof(password));
                fprintf(stderr, "EDP_FUSE_AUTHOPEN_READONLY_FAILED\n");
                return 65;
            }
            block_handle = edp_ro_open_device_fd(
                raw_fd, argv[3], argv[4], (unsigned long long)device_size,
                password, (unsigned long long)password_length, partition_type
            );
            close(raw_fd);
        } else {
            block_handle = edp_ro_open_device(
                argv[2], argv[3], argv[4],
                (unsigned long long)device_size,
                password,
                (unsigned long long)password_length,
                partition_type
            );
        }
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
    char *foreground_argv[] = {
        argv[0],
        "-f",
        "-o",
        options,
        (char *)mountpoint,
        NULL,
    };
    fprintf(stderr, "EDP_FUSE_BLOCK_SIZE=%llu\n", (unsigned long long)volume_size);
    int rc = fuse_main(5, foreground_argv, &ops, NULL);
    edp_ro_close(block_handle);
    block_handle = NULL;
    return rc;
}
