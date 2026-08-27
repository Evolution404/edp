#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int parse_id(const char *text, unsigned long *value) {
    if (!text || !*text || !value) return -1;
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || !end || *end != '\0') return -1;
    *value = parsed;
    return 0;
}

static int allowed_executable(const char *path) {
    static const char *allowed[] = {
        "/Library/Application Support/EDP USB Vault/bin/edp-fuset-readwrite",
        "/Library/Application Support/EDP USB Vault/bin/edp-readwrite-fuse",
        "/Library/Application Support/EDP USB Vault/bin/ntfs-3g",
        "/Library/Application Support/EDP USB Vault/bin/ntfs-3g.probe",
    };
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); ++index) {
        if (strcmp(path, allowed[index]) == 0) return 1;
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
    if (argc < 5) {
        fprintf(stderr, "usage: edp-console-exec <uid> <gid> [--raw-device /dev/rdiskN] -- <executable> [args...]\n");
        return 64;
    }
    if (geteuid() != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_REQUIRES_ROOT\n");
        return 77;
    }

    const char *raw_device = NULL;
    int separator = 3;
    if (argc >= 7 && strcmp(argv[3], "--raw-device") == 0) {
        raw_device = argv[4];
        separator = 5;
    }
    if (separator >= argc - 1 || strcmp(argv[separator], "--") != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INVALID_ARGUMENTS\n");
        return 64;
    }
    int executable_index = separator + 1;

    unsigned long uid_value = 0;
    unsigned long gid_value = 0;
    if (parse_id(argv[1], &uid_value) != 0 || parse_id(argv[2], &gid_value) != 0 ||
        uid_value == 0 || uid_value > UINT_MAX || gid_value > UINT_MAX) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INVALID_IDENTITY\n");
        return 64;
    }

    char resolved[PATH_MAX];
    if (!realpath(argv[executable_index], resolved) || !allowed_executable(resolved)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_REFUSED\n");
        return 77;
    }
    struct stat status;
    if (stat(resolved, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != 0 || (status.st_mode & 0022) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_UNTRUSTED\n");
        return 77;
    }

    int raw_fd = -1;
    if (raw_device) {
        static const char bridge[] =
            "/Library/Application Support/EDP USB Vault/bin/edp-fuset-readwrite";
        if (strcmp(resolved, bridge) != 0 || !is_whole_raw_disk_path(raw_device)) {
            fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_DEVICE_REFUSED\n");
            return 77;
        }
        raw_fd = open(raw_device, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        if (raw_fd < 0) {
            fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_OPEN_FAILED:%d\n", errno);
            return 77;
        }
        struct stat raw_status;
        if (fstat(raw_fd, &raw_status) != 0 || !S_ISCHR(raw_status.st_mode)) {
            fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_TYPE_REFUSED\n");
            close(raw_fd);
            return 77;
        }
        if (raw_fd != 3) {
            if (dup2(raw_fd, 3) < 0) {
                fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_DUP_FAILED:%d\n", errno);
                close(raw_fd);
                return 77;
            }
            close(raw_fd);
            raw_fd = 3;
        } else if (fcntl(raw_fd, F_SETFD, 0) != 0) {
            fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_INHERIT_FAILED:%d\n", errno);
            close(raw_fd);
            return 77;
        }
    }

    uid_t uid = (uid_t)uid_value;
    gid_t gid = (gid_t)gid_value;
    struct passwd *account = getpwuid(uid);
    if (!account || account->pw_uid != uid || initgroups(account->pw_name, gid) != 0 ||
        setgid(gid) != 0 || setuid(uid) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_DROP_FAILED:%d\n", errno);
        return 77;
    }
    if (setenv("HOME", account->pw_dir, 1) != 0 ||
        setenv("USER", account->pw_name, 1) != 0 ||
        setenv("LOGNAME", account->pw_name, 1) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_ENV_FAILED:%d\n", errno);
        return 77;
    }

    execv(resolved, &argv[executable_index]);
    fprintf(stderr, "EDP_CONSOLE_EXEC_EXEC_FAILED:%d\n", errno);
    return 71;
}
