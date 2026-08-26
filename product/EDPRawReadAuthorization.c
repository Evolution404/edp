#include <Security/Authorization.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int receive_fd(int socket_fd) {
    char payload = 0;
    struct iovec iov = { .iov_base = &payload, .iov_len = sizeof(payload) };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    ssize_t received;
    do {
        received = recvmsg(socket_fd, &message, 0);
    } while (received < 0 && errno == EINTR);
    if (received <= 0) return -1;

    for (struct cmsghdr *item = CMSG_FIRSTHDR(&message);
         item != NULL;
         item = CMSG_NXTHDR(&message, item)) {
        if (item->cmsg_level == SOL_SOCKET && item->cmsg_type == SCM_RIGHTS &&
            item->cmsg_len >= CMSG_LEN(sizeof(int))) {
            int fd = -1;
            memcpy(&fd, CMSG_DATA(item), sizeof(fd));
            return fd;
        }
    }
    return -1;
}

static int is_whole_raw_disk_path(const char *path) {
    static const char prefix[] = "/dev/rdisk";
    if (path == NULL || strncmp(path, prefix, sizeof(prefix) - 1) != 0) return 0;
    const char *suffix = path + sizeof(prefix) - 1;
    if (*suffix == '\0') return 0;
    for (; *suffix != '\0'; ++suffix) {
        if (*suffix < '0' || *suffix > '9') return 0;
    }
    return 1;
}

// This is deliberately the only raw-device authorization surface exposed to
// the sparse-backup tool. It can request read-only access and has no write mode.
int edp_authopen_readonly_fd(const char *path,
                             const void *authorization_bytes,
                             size_t authorization_length) {
    if (path == NULL || authorization_bytes == NULL ||
        authorization_length != sizeof(AuthorizationExternalForm) ||
        !is_whole_raw_disk_path(path)) {
        errno = EINVAL;
        return -1;
    }

    int sockets[2] = { -1, -1 };
    int input_pipe[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return -1;
    if (pipe(input_pipe) != 0) {
        int saved = errno;
        close(sockets[0]);
        close(sockets[1]);
        errno = saved;
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        int saved = errno;
        close(sockets[0]); close(sockets[1]);
        close(input_pipe[0]); close(input_pipe[1]);
        errno = saved;
        return -1;
    }
    if (child == 0) {
        close(sockets[0]);
        close(input_pipe[1]);
        if (dup2(input_pipe[0], STDIN_FILENO) < 0 ||
            dup2(sockets[1], STDOUT_FILENO) < 0) {
            _exit(126);
        }
        close(input_pipe[0]);
        close(sockets[1]);

        char flags[32];
        snprintf(flags, sizeof(flags), "%d", O_RDONLY | O_CLOEXEC);
        execl("/usr/libexec/authopen", "authopen", "-stdoutpipe", "-extauth",
              "-o", flags, path, (char *)NULL);
        _exit(127);
    }

    close(sockets[1]);
    close(input_pipe[0]);
    const uint8_t *cursor = authorization_bytes;
    size_t remaining = authorization_length;
    while (remaining > 0) {
        ssize_t written = write(input_pipe[1], cursor, remaining);
        if (written < 0) {
            if (errno == EINTR) continue;
            break;
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    close(input_pipe[1]);

    int raw_fd = receive_fd(sockets[0]);
    int receive_errno = errno;
    close(sockets[0]);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (raw_fd < 0) {
        if (WIFEXITED(status)) {
            fprintf(stderr, "EDP_BACKUP_AUTHOPEN_EXIT_STATUS=%d\n", WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            fprintf(stderr, "EDP_BACKUP_AUTHOPEN_SIGNAL=%d\n", WTERMSIG(status));
        }
        errno = receive_errno != 0 ? receive_errno : EACCES;
    }
    return raw_fd;
}
