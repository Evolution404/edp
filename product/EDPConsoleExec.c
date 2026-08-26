#include <errno.h>
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
        "/Library/Application Support/EDP USB Vault/bin/edp-readwrite-fuse",
        "/Library/Application Support/EDP USB Vault/bin/ntfs-3g",
        "/Library/Application Support/EDP USB Vault/bin/ntfs-3g.probe",
        "/Library/Application Support/EDP USB Vault/bin/ntfs-3g.probe",
    };
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); ++index) {
        if (strcmp(path, allowed[index]) == 0) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: edp-console-exec <uid> <gid> -- <executable> [args...]\n");
        return 64;
    }
    if (geteuid() != 0 || strcmp(argv[3], "--") != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_REQUIRES_ROOT\n");
        return 77;
    }

    unsigned long uid_value = 0;
    unsigned long gid_value = 0;
    if (parse_id(argv[1], &uid_value) != 0 || parse_id(argv[2], &gid_value) != 0 ||
        uid_value == 0 || uid_value > UINT_MAX || gid_value > UINT_MAX) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INVALID_IDENTITY\n");
        return 64;
    }

    char resolved[PATH_MAX];
    if (!realpath(argv[4], resolved) || !allowed_executable(resolved)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_REFUSED\n");
        return 77;
    }
    struct stat status;
    if (stat(resolved, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != 0 || (status.st_mode & 0022) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_UNTRUSTED\n");
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

    execv(resolved, &argv[4]);
    fprintf(stderr, "EDP_CONSOLE_EXEC_EXEC_FAILED:%d\n", errno);
    return 71;
}
