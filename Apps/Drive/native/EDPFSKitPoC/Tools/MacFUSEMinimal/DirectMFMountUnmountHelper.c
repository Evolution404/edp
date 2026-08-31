#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

static int enumerate_mounts(struct statfs **mounts_out) {
    errno = 0;
    int count = getmntinfo(mounts_out, MNT_NOWAIT);
    if (count < 0 || *mounts_out == NULL) {
        int failure = errno == 0 ? EIO : errno;
        return -failure;
    }
    return count;
}

static const struct statfs *mount_for_mountpoint(const char *mountpoint) {
    struct statfs *mounts = NULL;
    int count = enumerate_mounts(&mounts);
    if (count < 0) {
        return NULL;
    }
    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_mntonname, mountpoint) == 0) {
            return &mounts[index];
        }
    }
    return NULL;
}

static const struct statfs *mount_for_source(const char *source) {
    struct statfs *mounts = NULL;
    int count = enumerate_mounts(&mounts);
    if (count < 0) {
        return NULL;
    }
    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_mntfromname, source) == 0) {
            return &mounts[index];
        }
    }
    return NULL;
}

static int copy_mount_source(const char *mountpoint,
                             char *source,
                             size_t source_size) {
    const struct statfs *entry = mount_for_mountpoint(mountpoint);
    if (entry == NULL) {
        return ENOENT;
    }
    const char *candidate = entry->f_mntfromname;
    if (strncmp(candidate, "/dev/disk", strlen("/dev/disk")) != 0) {
        return ENODEV;
    }
    int length = snprintf(source, source_size, "%s", candidate);
    if (length < 0 || (size_t)length >= source_size) {
        return ENAMETOOLONG;
    }
    return 0;
}

static int assert_no_fskit_mounts(void) {
    struct statfs *mounts = NULL;
    int count = enumerate_mounts(&mounts);
    if (count < 0) {
        fprintf(stderr, "FSKIT_MOUNT_ENUMERATION_FAILED errno=%d\n", -count);
        return 2;
    }

    int found = 0;
    for (int index = 0; index < count; index++) {
        if ((mounts[index].f_flags_ext & MNT_EXT_FSKIT) == 0) {
            continue;
        }
        found++;
        fprintf(stderr,
                "FSKIT_MOUNT_PRESENT source=%s mountpoint=%s\n",
                mounts[index].f_mntfromname,
                mounts[index].f_mntonname);
    }
    if (found != 0) {
        fprintf(stderr, "FSKIT_MOUNT_COUNT=%d\n", found);
        return 1;
    }
    fprintf(stderr, "FSKIT_MOUNT_COUNT=0\n");
    return 0;
}

static int assert_no_macfuse_mounts_outside(const char *prefix) {
    struct statfs *mounts = NULL;
    int count = enumerate_mounts(&mounts);
    if (count < 0) {
        return 2;
    }
    size_t prefix_length = strlen(prefix);
    int found = 0;
    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_fstypename, "macfuse") != 0) {
            continue;
        }
        if (strncmp(mounts[index].f_mntonname, prefix, prefix_length) == 0) {
            continue;
        }
        found++;
        fprintf(stderr,
                "MACFUSE_OUTSIDE_MOUNT source=%s mountpoint=%s\n",
                mounts[index].f_mntfromname,
                mounts[index].f_mntonname);
    }
    return found == 0 ? 0 : 1;
}

static int assert_no_mount_prefix(const char *prefix) {
    struct statfs *mounts = NULL;
    int count = enumerate_mounts(&mounts);
    if (count < 0) {
        return 2;
    }
    size_t prefix_length = strlen(prefix);
    int found = 0;
    for (int index = 0; index < count; index++) {
        if (strncmp(mounts[index].f_mntonname, prefix, prefix_length) != 0) {
            continue;
        }
        found++;
        fprintf(stderr,
                "MOUNT_PREFIX_PRESENT source=%s mountpoint=%s\n",
                mounts[index].f_mntfromname,
                mounts[index].f_mntonname);
    }
    return found == 0 ? 0 : 1;
}

static int print_mount_source(const char *mountpoint) {
    const struct statfs *entry = mount_for_mountpoint(mountpoint);
    if (entry == NULL) {
        return 1;
    }
    printf("%s\n", entry->f_mntfromname);
    return 0;
}

static int print_mountpoint_for_source(const char *source) {
    const struct statfs *entry = mount_for_source(source);
    if (entry == NULL) {
        return 1;
    }
    printf("%s\n", entry->f_mntonname);
    return 0;
}

static int assert_mount_readonly(const char *mountpoint, int expected_readonly) {
    const struct statfs *entry = mount_for_mountpoint(mountpoint);
    if (entry == NULL) {
        return 1;
    }
    int readonly = (entry->f_flags & MNT_RDONLY) != 0;
    return readonly == expected_readonly ? 0 : 1;
}

static int is_macfuse_mount(const char *mountpoint) {
    const struct statfs *entry = mount_for_mountpoint(mountpoint);
    if (entry == NULL) {
        return 1;
    }
    return strcmp(entry->f_fstypename, "macfuse") == 0 ? 0 : 1;
}

static int usage(const char *program) {
    fprintf(stderr,
            "usage: %s <mountpoint>|--assert-no-fskit-mounts|"
            "--is-mounted <mountpoint>|--mount-source <mountpoint>|"
            "--mountpoint-for-source <source>|--assert-readonly <mountpoint>|"
            "--assert-writable <mountpoint>|--is-macfuse-mount <mountpoint>|"
            "--assert-no-macfuse-mounts-outside <prefix>|"
            "--assert-no-mount-prefix <prefix>\n",
            program);
    return 64;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--assert-no-fskit-mounts") == 0) {
        return assert_no_fskit_mounts();
    }
    if (argc == 3 && strcmp(argv[1], "--is-mounted") == 0) {
        return mount_for_mountpoint(argv[2]) == NULL ? 1 : 0;
    }
    if (argc == 3 && strcmp(argv[1], "--mount-source") == 0) {
        return print_mount_source(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "--mountpoint-for-source") == 0) {
        return print_mountpoint_for_source(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "--assert-readonly") == 0) {
        return assert_mount_readonly(argv[2], 1);
    }
    if (argc == 3 && strcmp(argv[1], "--assert-writable") == 0) {
        return assert_mount_readonly(argv[2], 0);
    }
    if (argc == 3 && strcmp(argv[1], "--is-macfuse-mount") == 0) {
        return is_macfuse_mount(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "--assert-no-macfuse-mounts-outside") == 0) {
        return assert_no_macfuse_mounts_outside(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "--assert-no-mount-prefix") == 0) {
        return assert_no_mount_prefix(argv[2]);
    }
    if (argc != 2) {
        return usage(argv[0]);
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
