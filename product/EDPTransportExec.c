#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int executable_dir(char *buffer, size_t capacity) {
    uint32_t size = (uint32_t)capacity;
    if (_NSGetExecutablePath(buffer, &size) != 0) {
        errno = ENAMETOOLONG;
        return -1;
    }
    char resolved[PATH_MAX];
    if (realpath(buffer, resolved) == NULL) return -1;
    char *slash = strrchr(resolved, '/');
    if (slash == NULL) { errno = EINVAL; return -1; }
    *slash = '\0';
    if (strlen(resolved) + 1 > capacity) { errno = ENAMETOOLONG; return -1; }
    strcpy(buffer, resolved);
    return 0;
}

int main(int argc, char **argv) {
    (void)argc;
    const char *backend = getenv("EDP_TRANSPORT");
    if (backend == NULL || *backend == '\0') backend = "macfuse-local";

    const char *target_name = NULL;
    if (strcmp(backend, "fuset") == 0) {
        target_name = "edp-fuset-readwrite-backend";
    } else if (strcmp(backend, "macfuse-local") == 0) {
        target_name = "edp-mfmount-local-readwrite";
    } else {
        fprintf(stderr, "EDP_TRANSPORT_EXEC_INVALID_BACKEND=%s\n", backend);
        return 64;
    }

    char dir[PATH_MAX];
    if (executable_dir(dir, sizeof(dir)) != 0) {
        perror("EDPTransportExec executable_dir");
        return 70;
    }
    char target[PATH_MAX];
    int written = snprintf(target, sizeof(target), "%s/%s", dir, target_name);
    if (written < 0 || (size_t)written >= sizeof(target)) return 70;

    if (access(target, X_OK) != 0) {
        fprintf(stderr, "EDP_TRANSPORT_EXEC_BACKEND_MISSING=%s\n", target);
        return 69;
    }
    fprintf(stderr, "EDP_TRANSPORT_EXEC_SELECTED=%s\n", backend);
    execv(target, argv);
    perror("EDPTransportExec execv");
    return 71;
}
