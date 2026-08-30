#include <MFMount/MFMount.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern void *edp_rw_open(const char *cipher_path, const char *key_hex);
extern void *edp_rw_open_device(const char *raw_path, const char *vid_hex,
                                const char *pid_hex, unsigned long long device_size_bytes,
                                const unsigned char *password, unsigned long long password_length,
                                uint32_t partition_type);
extern unsigned long long edp_rw_size(void *handle);
extern long long edp_rw_read(void *handle, unsigned long long offset, void *buffer,
                             unsigned long long requested_length);
extern long long edp_rw_write(void *handle, unsigned long long offset,
                              const void *buffer,
                              unsigned long long requested_length);
extern int32_t edp_rw_sync(void *handle);
extern int32_t edp_rw_close(void *handle);

static void *g_edp_handle = NULL;
static const int g_virtual_fd = 0x4d46;
static const char *g_mountpoint = NULL;

static int fixture_open(const char *path, int flags, ...) {
    (void)flags;
    if (strcmp(path, "EDP_ENCRYPTED_FIXTURE") != 0 || g_edp_handle == NULL) {
        errno = ENOENT;
        return -1;
    }
    return g_virtual_fd;
}

static int fixture_fstat(int fd, struct stat *st) {
    if (fd != g_virtual_fd || g_edp_handle == NULL) { errno = EBADF; return -1; }
    memset(st, 0, sizeof(*st));
    st->st_mode = S_IFREG | 0600;
    st->st_size = (off_t)edp_rw_size(g_edp_handle);
    return 0;
}

static ssize_t fixture_pread(int fd, void *buffer, size_t size, off_t offset) {
    if (fd != g_virtual_fd || g_edp_handle == NULL || offset < 0) { errno = EBADF; return -1; }
    long long result = edp_rw_read(g_edp_handle, (unsigned long long)offset, buffer, size);
    if (result < 0) { errno = (int)-result; return -1; }
    return (ssize_t)result;
}

static ssize_t fixture_pwrite(int fd, const void *buffer, size_t size, off_t offset) {
    if (fd != g_virtual_fd || g_edp_handle == NULL || offset < 0) { errno = EBADF; return -1; }
    long long result = edp_rw_write(g_edp_handle, (unsigned long long)offset, buffer, size);
    if (result < 0) { errno = (int)-result; return -1; }
    return (ssize_t)result;
}

static int fixture_fsync(int fd) {
    if (fd != g_virtual_fd || g_edp_handle == NULL) { errno = EBADF; return -1; }
    int32_t result = edp_rw_sync(g_edp_handle);
    if (result < 0) { errno = -result; return -1; }
    return 0;
}

static int fixture_close(int fd) {
    if (fd == g_virtual_fd) return 0;
    return close(fd);
}

/* A SIGTERM/SIGINT close is performed by EDPAsyncMFMount's sigwait thread.
 * The shared server loop then observes ENODEV. Its normal tail still calls
 * MFChannelClose(), so suppress that second close because MFMount explicitly
 * treats closing an already-closed channel as a programming error. */
static bool fixture_channel_close(MFChannelRef channel) {
    MFChannelFlags flags = 0;
    errno = 0;
    if (!MFChannelGetFlags(channel, &flags) && errno == ENODEV) {
        fprintf(stderr,
                "DIRECT_MFMOUNT_CHANNEL_ALREADY_CLOSED=1 mountpoint=%s\n",
                g_mountpoint == NULL ? "<unset>" : g_mountpoint);
        return true;
    }
    return MFChannelClose(channel);
}

#define open fixture_open
#define fstat fixture_fstat
#define pread fixture_pread
#define pwrite fixture_pwrite
#define fsync fixture_fsync
#define close fixture_close
#define MFChannelClose fixture_channel_close
#define main edp_direct_raw_main
#include "DirectMFMountRawTransport.c"
#undef main
#undef MFChannelClose
#undef close
#undef fsync
#undef pwrite
#undef pread
#undef fstat
#undef open

static const char *fixture_value_after(int argc, char **argv, const char *key) {
    for (int index = 1; index + 1 < argc; index++) {
        if (strcmp(argv[index], key) == 0) return argv[index + 1];
    }
    return NULL;
}

static int read_fixture_password(const char *path, unsigned char *buffer,
                                 size_t capacity, size_t *length_out) {
    if (path == NULL || buffer == NULL || length_out == NULL) return -1;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t total = 0;
    while (total < capacity) {
        ssize_t count = read(fd, buffer + total, capacity - total);
        if (count < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (count == 0) break;
        total += (size_t)count;
    }
    close(fd);
    while (total > 0 && (buffer[total - 1] == '\n' || buffer[total - 1] == '\r')) total--;
    *length_out = total;
    return total > 0 ? 0 : -1;
}

static void fixture_secure_zero(void *buffer, size_t length) {
    volatile unsigned char *bytes = (volatile unsigned char *)buffer;
    while (length-- > 0) *bytes++ = 0;
}

int main(int argc, char **argv) {
    const char *mountpoint = NULL;
    const char *volume_name = NULL;
    bool read_only = false;

    if (argc == 5) {
        mountpoint = argv[3];
        volume_name = argv[4];
        g_edp_handle = edp_rw_open(argv[1], argv[2]);
    } else {
        const char *raw_path = fixture_value_after(argc, argv, "--raw-device-file");
        const char *vid = fixture_value_after(argc, argv, "--vid");
        const char *pid = fixture_value_after(argc, argv, "--pid");
        const char *device_size_text = fixture_value_after(argc, argv, "--device-size");
        const char *partition_text = fixture_value_after(argc, argv, "--partition-type");
        const char *password_file = fixture_value_after(argc, argv, "--password-file");
        mountpoint = fixture_value_after(argc, argv, "--mountpoint");
        volume_name = fixture_value_after(argc, argv, "--volume-name");
        if (raw_path == NULL || vid == NULL || pid == NULL || device_size_text == NULL ||
            partition_text == NULL || mountpoint == NULL || volume_name == NULL) {
            fprintf(stderr,
                    "usage: %s <cipher.img> <32-hex-key> <mountpoint> <volume-name>\n"
                    "   or: %s --raw-device-file FILE --vid HEX --pid HEX --device-size BYTES "
                    "--partition-type {1|2|4} --password-file FILE --mountpoint PATH --volume-name NAME\n",
                    argv[0], argv[0]);
            return 64;
        }
        char *end = NULL;
        unsigned long long device_size = strtoull(device_size_text, &end, 10);
        if (end == NULL || *end != '\0' || device_size == 0) return 64;
        end = NULL;
        unsigned long partition = strtoul(partition_text, &end, 10);
        if (end == NULL || *end != '\0' || (partition != 1 && partition != 2 && partition != 4)) return 64;
        read_only = partition == 1;

        unsigned char password[4096];
        size_t password_length = 0;
        memset(password, 0, sizeof(password));
        if (partition != 1 &&
            read_fixture_password(password_file, password, sizeof(password), &password_length) != 0) {
            fixture_secure_zero(password, sizeof(password));
            fprintf(stderr, "EDP_DIRECT_FIXTURE_PASSWORD_READ_FAILED\n");
            return 65;
        }
        g_edp_handle = edp_rw_open_device(
            raw_path, vid, pid, device_size,
            partition == 1 ? NULL : password,
            partition == 1 ? 0 : (unsigned long long)password_length,
            (uint32_t)partition
        );
        fixture_secure_zero(password, sizeof(password));
    }

    g_mountpoint = mountpoint;
    if (g_edp_handle == NULL) {
        fprintf(stderr, "EDP_DIRECT_FIXTURE_OPEN_FAILED\n");
        return 65;
    }
    char *direct_argv[] = {
        argv[0],
        "EDP_ENCRYPTED_FIXTURE",
        (char *)mountpoint,
        (char *)volume_name,
        read_only ? "readonly" : NULL,
        NULL,
    };
    int result = edp_direct_raw_main(read_only ? 5 : 4, direct_argv);
    /* edp_rw_close owns the final strong durability barrier, matching the
     * production inherited-raw-fd adapter. */
    int32_t close_result = edp_rw_close(g_edp_handle);
    fprintf(stderr, "EDP_FINAL_DURABILITY status=%d\n", close_result);
    if (close_result != 0 && result == 0) result = 5;
    g_edp_handle = NULL;
    g_mountpoint = NULL;
    return result;
}
