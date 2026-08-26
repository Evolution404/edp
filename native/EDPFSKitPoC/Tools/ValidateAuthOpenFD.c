#include <Security/Authorization.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int receive_fd(int socket_fd) {
    char payload = 0;
    struct iovec iov = { .iov_base = &payload, .iov_len = sizeof(payload) };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    ssize_t received = recvmsg(socket_fd, &msg, 0);
    if (received <= 0) return -1;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
         cmsg != NULL;
         cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
            int fd = -1;
            memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
            return fd;
        }
    }
    return -1;
}

static int authopen_fd(const char *path, int open_flags,
                       const AuthorizationExternalForm *external_form) {
    int sockets[2];
    int stdin_pipe[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        perror("socketpair");
        return -1;
    }
    if (pipe(stdin_pipe) != 0) {
        perror("pipe");
        close(sockets[0]);
        close(sockets[1]);
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        close(sockets[0]); close(sockets[1]);
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        return -1;
    }
    if (child == 0) {
        close(sockets[0]);
        close(stdin_pipe[1]);
        if (dup2(stdin_pipe[0], STDIN_FILENO) < 0 ||
            dup2(sockets[1], STDOUT_FILENO) < 0) {
            _exit(126);
        }
        close(stdin_pipe[0]);
        close(sockets[1]);

        char flags_buf[32];
        snprintf(flags_buf, sizeof(flags_buf), "%d", open_flags);
        execl("/usr/libexec/authopen", "authopen",
              "-stdoutpipe", "-extauth", "-o", flags_buf, path, (char *)NULL);
        _exit(127);
    }

    close(sockets[1]);
    close(stdin_pipe[0]);
    const uint8_t *form_bytes = (const uint8_t *)external_form;
    size_t remaining = sizeof(*external_form);
    while (remaining > 0) {
        ssize_t n = write(stdin_pipe[1], form_bytes, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("write authorization form");
            break;
        }
        form_bytes += n;
        remaining -= (size_t)n;
    }
    close(stdin_pipe[1]);

    int fd = receive_fd(sockets[0]);
    close(sockets[0]);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (fd < 0) {
        if (WIFEXITED(status)) {
            fprintf(stderr, "authopen exited status=%d flags=%d\n", WEXITSTATUS(status), open_flags);
        } else if (WIFSIGNALED(status)) {
            fprintf(stderr, "authopen signaled=%d flags=%d\n", WTERMSIG(status), open_flags);
        }
        return -1;
    }
    return fd;
}

static int authorize_path(const char *path, int generic_admin,
                          AuthorizationRef *authorization,
                          AuthorizationExternalForm *external_form) {
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                          kAuthorizationFlagDefaults, authorization);
    if (status != errAuthorizationSuccess) {
        fprintf(stderr, "AuthorizationCreate status=%d\n", (int)status);
        return 1;
    }

    char readonly_right[PATH_MAX + 64];
    char readwrite_right[PATH_MAX + 64];
    snprintf(readonly_right, sizeof(readonly_right), "sys.openfile.readonly.%s", path);
    snprintf(readwrite_right, sizeof(readwrite_right), "sys.openfile.readwrite.%s", path);
    AuthorizationItem path_items[2] = {
        { readonly_right, 0, NULL, 0 },
        { readwrite_right, 0, NULL, 0 },
    };
    AuthorizationItem admin_item = { "system.privilege.admin", 0, NULL, 0 };
    AuthorizationRights rights = generic_admin
        ? (AuthorizationRights){ 1, &admin_item }
        : (AuthorizationRights){ 2, path_items };
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed |
                               kAuthorizationFlagExtendRights |
                               kAuthorizationFlagPreAuthorize;
    status = AuthorizationCopyRights(*authorization, &rights,
                                     kAuthorizationEmptyEnvironment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        fprintf(stderr, "AuthorizationCopyRights status=%d\n", (int)status);
        AuthorizationFree(*authorization, kAuthorizationFlagDefaults);
        *authorization = NULL;
        return 1;
    }
    status = AuthorizationMakeExternalForm(*authorization, external_form);
    if (status != errAuthorizationSuccess) {
        fprintf(stderr, "AuthorizationMakeExternalForm status=%d\n", (int)status);
        AuthorizationFree(*authorization, kAuthorizationFlagDefaults);
        *authorization = NULL;
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "usage: %s /dev/rdiskN [--generic-admin] [--free-before-open]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    int generic_admin = 0;
    int free_before_open = 0;
    for (int i = 2; i < argc; ++i) {
        if (strcmp(argv[i], "--generic-admin") == 0) generic_admin = 1;
        else if (strcmp(argv[i], "--free-before-open") == 0) free_before_open = 1;
        else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            return 2;
        }
    }
    AuthorizationRef authorization = NULL;
    AuthorizationExternalForm external_form;
    if (authorize_path(path, generic_admin, &authorization, &external_form) != 0) return 1;
    printf("AUTHORIZATION_MODE=%s\n", generic_admin ? "generic-admin" : "path-specific");
    if (free_before_open) {
        AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        authorization = NULL;
        printf("AUTHORIZATION_REF_FREED_BEFORE_AUTHOPEN=YES\n");
    }

    int read_fd = authopen_fd(path, O_RDONLY | O_CLOEXEC, &external_form);
    if (read_fd < 0) {
        if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        return 1;
    }
    unsigned char sector[512];
    ssize_t n = pread(read_fd, sector, sizeof(sector), 2048);
    int read_errno = errno;
    close(read_fd);
    if (n != (ssize_t)sizeof(sector)) {
        fprintf(stderr, "AUTHORIZED_PREAD_FAILED rc=%zd errno=%d %s\n",
                n, read_errno, strerror(read_errno));
        if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        return 1;
    }
    size_t nonzero = 0;
    for (size_t i = 0; i < sizeof(sector); ++i) if (sector[i] != 0) ++nonzero;
    printf("AUTHORIZED_READ_FD_OK bytes=%zd nonzero=%zu first16=", n, nonzero);
    for (int i = 0; i < 16; ++i) printf("%02x", sector[i]);
    printf("\n");

    int rw_fd = authopen_fd(path, O_RDWR | O_CLOEXEC, &external_form);
    if (rw_fd < 0) {
        if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
        return 1;
    }
    int descriptor_flags = fcntl(rw_fd, F_GETFL);
    close(rw_fd);
    printf("AUTHORIZED_RDWR_FD_OK flags=0x%x NO_WRITE_PERFORMED=YES\n", descriptor_flags);

    if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
    printf("RESULT=AUTHOPEN_RAW_DEVICE_READ_AND_RDWR_OPEN_OK\n");
    return 0;
}
