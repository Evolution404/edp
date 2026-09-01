#include "EDPRawValidation.h"

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdint.h>
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
        "/Library/Application Support/EDP Drive/bin/edp-mfmount-local-readwrite",
        "/Library/Application Support/EDP Drive/bin/edp-mfmount-local-readonly",
        "/Library/Application Support/EDP Drive/bin/diskimages2-attach",
    };
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); ++index) {
        if (strcmp(path, allowed[index]) == 0) return 1;
    }
    return 0;
}

static int is_raw_bridge_executable(const char *path) {
    static const char *allowed[] = {
        "/Library/Application Support/EDP Drive/bin/edp-mfmount-local-readwrite",
        "/Library/Application Support/EDP Drive/bin/edp-mfmount-local-readonly",
    };
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); ++index) {
        if (strcmp(path, allowed[index]) == 0) return 1;
    }
    return 0;
}

static int prepare_inherited_raw_fd(void) {
    int descriptor_flags = fcntl(3, F_GETFD);
    struct stat status;
    if (descriptor_flags < 0 || fstat(3, &status) != 0 || !S_ISCHR(status.st_mode)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INHERITED_RAW_INVALID:%d\n", errno);
        return -1;
    }
    if (!edp_fd_has_edp_metadata(3)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INHERITED_RAW_METADATA_REFUSED\n");
        errno = EPERM;
        return -1;
    }
    if ((descriptor_flags & FD_CLOEXEC) != 0 &&
        fcntl(3, F_SETFD, descriptor_flags & ~FD_CLOEXEC) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INHERITED_RAW_INHERIT_FAILED:%d\n", errno);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_REQUIRES_ROOT\n");
        return 77;
    }
    if (argc < 5 || strcmp(argv[3], "--") != 0) {
        fprintf(stderr, "usage: edp-console-exec <uid> <gid> -- <executable> [args...]\n");
        return 64;
    }

    unsigned long uid_value = 0;
    unsigned long gid_value = 0;
    if (parse_id(argv[1], &uid_value) != 0 || parse_id(argv[2], &gid_value) != 0 ||
        uid_value == 0 || uid_value > UINT_MAX || gid_value > UINT_MAX) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INVALID_IDENTITY\n");
        return 64;
    }

    const int executable_index = 4;
    char resolved[PATH_MAX];
    if (!realpath(argv[executable_index], resolved) || !allowed_executable(resolved)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_REFUSED\n");
        return 77;
    }
    struct stat target_status;
    if (stat(resolved, &target_status) != 0 || !S_ISREG(target_status.st_mode) ||
        target_status.st_uid != 0 || (target_status.st_mode & 0022) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_UNTRUSTED\n");
        return 77;
    }

    if (is_raw_bridge_executable(resolved) && prepare_inherited_raw_fd() != 0) {
        return 77;
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
