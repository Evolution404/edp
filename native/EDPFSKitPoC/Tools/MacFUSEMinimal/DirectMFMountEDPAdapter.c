#include <MFMount/MFMount.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

static void *g_edp_handle = NULL;
static const int g_virtual_fd = 0x4d46;
static const char *g_mountpoint = NULL;

static void secure_zero(void *buffer, size_t length) {
    volatile unsigned char *bytes = buffer;
    while (length-- > 0) *bytes++ = 0;
}

static int read_all_fd(int fd, unsigned char *buffer, size_t capacity, size_t *length_out) {
    size_t length = 0;
    while (length < capacity) {
        ssize_t count = read(fd, buffer + length, capacity - length);
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (count == 0) break;
        length += (size_t)count;
    }
    if (length == 0 || length == capacity) return -1;
    *length_out = length;
    return 0;
}

static int edp_backing_open(const char *path, int flags, ...) {
    (void)flags;
    if (strcmp(path, "EDP_ENCRYPTED_BACKING") != 0 || g_edp_handle == NULL) {
        errno = ENOENT;
        return -1;
    }
    return g_virtual_fd;
}

static int edp_backing_fstat(int fd, struct stat *st) {
    if (fd != g_virtual_fd || g_edp_handle == NULL) {
        errno = EBADF;
        return -1;
    }
    memset(st, 0, sizeof(*st));
    st->st_mode = S_IFREG | 0600;
    st->st_size = (off_t)edp_rw_size(g_edp_handle);
    return 0;
}

static ssize_t edp_backing_pread(int fd, void *buffer, size_t size, off_t offset) {
    if (fd != g_virtual_fd || g_edp_handle == NULL || offset < 0) {
        errno = EBADF;
        return -1;
    }
    long long result = edp_rw_read(g_edp_handle, (unsigned long long)offset, buffer, size);
    if (result < 0) {
        errno = (int)-result;
        return -1;
    }
    return (ssize_t)result;
}

static ssize_t edp_backing_pwrite(int fd, const void *buffer, size_t size, off_t offset) {
    if (fd != g_virtual_fd || g_edp_handle == NULL || offset < 0) {
        errno = EBADF;
        return -1;
    }
    long long result = edp_rw_write(g_edp_handle, (unsigned long long)offset, buffer, size);
    if (result < 0) {
        errno = (int)-result;
        return -1;
    }
    return (ssize_t)result;
}

static int edp_backing_fsync(int fd) {
    if (fd != g_virtual_fd || g_edp_handle == NULL) {
        errno = EBADF;
        return -1;
    }
    int32_t result = edp_rw_sync(g_edp_handle);
    if (result < 0) {
        errno = -result;
        return -1;
    }
    return 0;
}

static int edp_backing_close(int fd) {
    if (fd == g_virtual_fd) return 0;
    return close(fd);
}

/* EDPAsyncMFMount owns SIGTERM/SIGINT through a sigwait thread and wakes this
 * receive with MFChannelInterrupt(). Translate that one interruption into
 * ENODEV so the shared server loop exits and performs its single documented
 * MFChannelClose() teardown. Do not call unmount(2): Direct MFMount owns the
 * channel lifecycle. */
static MFMessageRef edp_next_message(MFChannelRef channel) {
    MFMessageRef message = MFChannelCopyNextMessage(channel);
    if (message == NULL && errno == EINTR) {
        fprintf(stderr,
                "DIRECT_TERMINATION_INTERRUPT_OBSERVED=1 mountpoint=%s\n",
                g_mountpoint == NULL ? "<unset>" : g_mountpoint);
        errno = ENODEV;
    }
    return message;
}

#define open edp_backing_open
#define fstat edp_backing_fstat
#define pread edp_backing_pread
#define pwrite edp_backing_pwrite
#define fsync edp_backing_fsync
#define close edp_backing_close
#define MFChannelCopyNextMessage edp_next_message
#define main edp_direct_raw_main
#include "DirectMFMountRawTransport.c"
#undef main
#undef MFChannelCopyNextMessage
#undef close
#undef fsync
#undef pwrite
#undef pread
#undef fstat
#undef open

static void usage(const char *program) {
    fprintf(stderr,
            "usage: %s --raw-device /dev/rdiskN --raw-fd FD --vid HEX --pid HEX "
            "--device-size BYTES --partition-type {2|4} --control-fd FD "
            "--mountpoint PATH --volume-name NAME\n",
            program);
}

static const char *value_after(int argc, char **argv, const char *key) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], key) == 0) return argv[i + 1];
    }
    return NULL;
}

int main(int argc, char **argv) {
    const char *raw_device = value_after(argc, argv, "--raw-device");
    const char *raw_fd_text = value_after(argc, argv, "--raw-fd");
    const char *vid = value_after(argc, argv, "--vid");
    const char *pid = value_after(argc, argv, "--pid");
    const char *device_size_text = value_after(argc, argv, "--device-size");
    const char *partition_text = value_after(argc, argv, "--partition-type");
    const char *control_fd_text = value_after(argc, argv, "--control-fd");
    const char *mountpoint = value_after(argc, argv, "--mountpoint");
    const char *volume_name = value_after(argc, argv, "--volume-name");
    if (!raw_device || !raw_fd_text || !vid || !pid || !device_size_text ||
        !partition_text || !control_fd_text || !mountpoint || !volume_name ||
        strncmp(raw_device, "/dev/rdisk", 10) != 0) {
        usage(argv[0]);
        return 64;
    }

    char *end = NULL;
    long raw_fd_long = strtol(raw_fd_text, &end, 10);
    if (!end || *end || raw_fd_long < 3 || raw_fd_long > INT32_MAX) return 64;
    int raw_fd = (int)raw_fd_long;
    end = NULL;
    unsigned long long device_size = strtoull(device_size_text, &end, 10);
    if (!end || *end || device_size == 0) return 64;
    end = NULL;
    unsigned long partition = strtoul(partition_text, &end, 10);
    if (!end || *end || (partition != 2 && partition != 4)) return 64;
    end = NULL;
    long control_fd_long = strtol(control_fd_text, &end, 10);
    if (!end || *end || control_fd_long < 0 || control_fd_long > INT32_MAX) return 64;

    struct stat raw_stat;
    if (fcntl(raw_fd, F_GETFD) < 0 || fstat(raw_fd, &raw_stat) != 0 || !S_ISCHR(raw_stat.st_mode)) {
        fprintf(stderr, "EDP_DIRECT_INVALID_INHERITED_RAW_FD\n");
        return 65;
    }

    unsigned char password[4096];
    size_t password_length = 0;
    if (read_all_fd((int)control_fd_long, password, sizeof(password), &password_length) != 0) {
        secure_zero(password, sizeof(password));
        fprintf(stderr, "EDP_DIRECT_CONTROL_FD_READ_FAILED\n");
        return 65;
    }

    g_mountpoint = mountpoint;
    g_edp_handle = edp_rw_open_device_fd(raw_fd, vid, pid, device_size,
                                         password, password_length,
                                         (uint32_t)partition);
    secure_zero(password, sizeof(password));
    if (g_edp_handle == NULL) {
        fprintf(stderr, "EDP_DIRECT_ENCRYPTED_BACKEND_OPEN_FAILED\n");
        return 65;
    }

    char *direct_argv[] = {
        argv[0],
        "EDP_ENCRYPTED_BACKING",
        (char *)mountpoint,
        (char *)volume_name,
        NULL,
    };
    int result = edp_direct_raw_main(4, direct_argv);
    (void)edp_rw_sync(g_edp_handle);
    edp_rw_close(g_edp_handle);
    g_edp_handle = NULL;
    g_mountpoint = NULL;
    return result;
}
