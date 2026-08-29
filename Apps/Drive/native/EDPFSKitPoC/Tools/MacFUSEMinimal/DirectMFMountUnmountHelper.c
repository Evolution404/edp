#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

static int copy_mount_source(const char *mountpoint,
                             char *source,
                             size_t source_size) {
    struct statfs *mounts = NULL;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    if (count <= 0) {
        return errno == 0 ? EIO : errno;
    }

    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_mntonname, mountpoint) != 0) {
            continue;
        }
        const char *candidate = mounts[index].f_mntfromname;
        if (strncmp(candidate, "/dev/disk", strlen("/dev/disk")) != 0) {
            return ENODEV;
        }
        int length = snprintf(source, source_size, "%s", candidate);
        if (length < 0 || (size_t)length >= source_size) {
            return ENAMETOOLONG;
        }
        return 0;
    }
    return ENOENT;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <mountpoint>\n", argv[0]);
        return 64;
    }

    char source[PATH_MAX];
    int source_result = copy_mount_source(argv[1], source, sizeof(source));
    if (source_result != 0) {
        fprintf(stderr,
                "DIRECT_MFMOUNT_PRIVILEGED_SOURCE_FAILED=%d mountpoint=%s\n",
                source_result,
                argv[1]);
        return 1;
    }
    fprintf(stderr,
            "DIRECT_MFMOUNT_PRIVILEGED_SOURCE=%s mountpoint=%s euid=%u\n",
            source,
            argv[1],
            (unsigned int)geteuid());

    fprintf(stderr,
            "DIRECT_MFMOUNT_PRIVILEGED_UNMOUNT_CALL=1 source=%s mountpoint=%s\n",
            source,
            argv[1]);
    fflush(stderr);
    errno = 0;
    int result = unmount(argv[1], MNT_FORCE);
    int saved_errno = errno;
    fprintf(stderr,
            "DIRECT_MFMOUNT_PRIVILEGED_UNMOUNT_RESULT=%d errno=%d "
            "source=%s mountpoint=%s\n",
            result,
            saved_errno,
            source,
            argv[1]);
    return result == 0 ? 0 : 1;
}
