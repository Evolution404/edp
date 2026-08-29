#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3 && argc != 5 && argc != 6) {
        fprintf(stderr, "usage: %s <device> <byte-offset> [drop-uid drop-gid [--open-rw-no-write]]\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(argv[2], &end, 0);
    if (errno != 0 || end == argv[2] || *end != '\0') {
        fprintf(stderr, "invalid offset\n");
        return 2;
    }
    if (argc >= 5) {
        uid_t drop_uid = (uid_t)strtoul(argv[3], NULL, 10);
        gid_t drop_gid = (gid_t)strtoul(argv[4], NULL, 10);
        if (setgid(drop_gid) != 0 || setuid(drop_uid) != 0) {
            printf("DROP_PRIVILEGES_RC=-1 ERRNO=%d ERROR=%s\n", errno, strerror(errno));
            return 1;
        }
    }
    printf("UID=%u EUID=%u GID=%u EGID=%u\n",
           (unsigned)getuid(), (unsigned)geteuid(),
           (unsigned)getgid(), (unsigned)getegid());
    int open_flags = O_RDONLY | O_CLOEXEC;
    if (argc == 6) {
        if (strcmp(argv[5], "--open-rw-no-write") != 0) {
            fprintf(stderr, "unknown mode: %s\n", argv[5]);
            return 2;
        }
        open_flags = O_RDWR | O_CLOEXEC;
    }
    int fd = open(argv[1], open_flags);
    if (fd < 0) {
        printf("OPEN_RC=-1 ERRNO=%d ERROR=%s\n", errno, strerror(errno));
        return 1;
    }
    if ((open_flags & O_RDWR) != 0) {
        close(fd);
        printf("RESULT=RAW_READ_WRITE_OPEN_ONLY_OK\n");
        return 0;
    }
    unsigned char block[512];
    ssize_t count = pread(fd, block, sizeof(block), (off_t)parsed);
    int saved = errno;
    close(fd);
    if (count < 0) {
        printf("PREAD_RC=-1 ERRNO=%d ERROR=%s\n", saved, strerror(saved));
        return 1;
    }
    size_t nonzero = 0;
    for (ssize_t i = 0; i < count; ++i) {
        if (block[i] != 0) ++nonzero;
    }
    printf("PREAD_RC=%zd NONZERO=%zu FIRST16=", count, nonzero);
    for (int i = 0; i < 16 && i < count; ++i) printf("%02x", block[i]);
    printf("\nRESULT=RAW_READ_ONLY_PROBE_OK\n");
    return count == (ssize_t)sizeof(block) ? 0 : 1;
}
