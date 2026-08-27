#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern void *edp_rw_open(const char *cipher_path, const char *key_hex);
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

#define open fixture_open
#define fstat fixture_fstat
#define pread fixture_pread
#define pwrite fixture_pwrite
#define fsync fixture_fsync
#define close fixture_close
#define main edp_direct_raw_main
#include "DirectMFMountRawTransport.c"
#undef main
#undef close
#undef fsync
#undef pwrite
#undef pread
#undef fstat
#undef open

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <cipher.img> <32-hex-key> <mountpoint> <volume-name>\n", argv[0]);
        return 64;
    }
    g_edp_handle = edp_rw_open(argv[1], argv[2]);
    if (g_edp_handle == NULL) {
        fprintf(stderr, "EDP_DIRECT_FIXTURE_OPEN_FAILED\n");
        return 65;
    }
    char *direct_argv[] = { argv[0], "EDP_ENCRYPTED_FIXTURE", argv[3], argv[4], NULL };
    int result = edp_direct_raw_main(4, direct_argv);
    (void)edp_rw_sync(g_edp_handle);
    edp_rw_close(g_edp_handle);
    g_edp_handle = NULL;
    return result;
}
