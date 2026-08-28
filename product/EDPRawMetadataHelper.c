#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define EDP_SECTOR_SIZE 512

static int write_all(int fd, const void *buffer, size_t length) {
    const unsigned char *cursor = (const unsigned char *)buffer;
    while (length > 0) {
        ssize_t n = write(fd, cursor, length);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        cursor += n;
        length -= (size_t)n;
    }
    return 0;
}

static int read_sector(int fd, uint64_t lba, unsigned char out[EDP_SECTOR_SIZE]) {
    off_t offset = (off_t)(lba * EDP_SECTOR_SIZE);
    size_t done = 0;
    while (done < EDP_SECTOR_SIZE) {
        ssize_t n = pread(fd, out + done, EDP_SECTOR_SIZE - done, offset + (off_t)done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int is_whole_raw_disk_path(const char *path) {
    static const char prefix[] = "/dev/rdisk";
    if (!path || strncmp(path, prefix, sizeof(prefix) - 1) != 0) return 0;
    const char *suffix = path + sizeof(prefix) - 1;
    if (*suffix == '\0') return 0;
    for (; *suffix != '\0'; ++suffix) {
        if (*suffix < '0' || *suffix > '9') return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s /dev/rdiskN console-uid\n", argv[0]);
        return 64;
    }
    if (geteuid() != 0) {
        fprintf(stderr, "helper must be launched by the privileged daemon\n");
        return 77;
    }
    if (!is_whole_raw_disk_path(argv[1])) {
        fprintf(stderr, "refusing non-whole raw-device path\n");
        return 64;
    }

    char *end = NULL;
    errno = 0;
    unsigned long parsed_uid = strtoul(argv[2], &end, 10);
    if (errno != 0 || end == argv[2] || *end != '\0' || parsed_uid == 0 || parsed_uid > UINT32_MAX) {
        fprintf(stderr, "invalid console uid\n");
        return 64;
    }

    gid_t operator_gid = 5;
    if (setgroups(1, &operator_gid) != 0 || setgid(operator_gid) != 0 || setuid((uid_t)parsed_uid) != 0) {
        fprintf(stderr, "privilege drop failed: errno=%d %s\n", errno, strerror(errno));
        return 77;
    }

    int fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        fprintf(stderr, "raw read-only open failed: errno=%d %s\n", errno, strerror(errno));
        return 74;
    }
    struct stat raw_status;
    if (fstat(fd, &raw_status) != 0 || !S_ISCHR(raw_status.st_mode)) {
        fprintf(stderr, "refusing non-character raw device\n");
        close(fd);
        return 74;
    }

    const uint64_t lbas[] = {4, 7, 11, 12};
    unsigned char sector[EDP_SECTOR_SIZE];
    for (size_t i = 0; i < sizeof(lbas) / sizeof(lbas[0]); ++i) {
        if (read_sector(fd, lbas[i], sector) != 0) {
            int saved = errno;
            close(fd);
            fprintf(stderr, "raw pread LBA%llu failed: errno=%d %s\n",
                    (unsigned long long)lbas[i], saved, strerror(saved));
            return 74;
        }
        if (write_all(STDOUT_FILENO, sector, sizeof(sector)) != 0) {
            close(fd);
            return 74;
        }
    }
    close(fd);
    return 0;
}
