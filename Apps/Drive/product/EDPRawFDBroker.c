#include "EDPRawValidation.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define EDP_RAW_BROKER_CHILD_SOCKET_FD 198
#define EDP_RAW_BROKER_APP_PATH "/Applications/EDP Drive.app/Contents/MacOS/EDP Drive"

struct edp_raw_broker_message {
    int32_t status;
    int32_t error_code;
};

static int send_broker_message(int socket_fd, int status, int error_code, int raw_fd) {
    struct edp_raw_broker_message payload = {
        .status = status,
        .error_code = error_code,
    };
    struct iovec iov = {
        .iov_base = &payload,
        .iov_len = sizeof(payload),
    };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;

    if (raw_fd >= 0) {
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        if (!header) return -1;
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(header), &raw_fd, sizeof(raw_fd));
    }

    for (;;) {
        ssize_t count = sendmsg(socket_fd, &message, 0);
        if (count < 0 && errno == EINTR) continue;
        return count == (ssize_t)sizeof(payload) ? 0 : -1;
    }
}

int edp_raw_fd_broker_run_child(int socket_fd, const char *raw_path) {
    if (geteuid() != 0 || socket_fd < 0 || !raw_path) {
        int error_code = EPERM;
        (void)send_broker_message(socket_fd, 1, error_code, -1);
        return 77;
    }

    int validation_error = EDP_RAW_VALIDATION_OK;
    int raw_fd = edp_open_validated_raw_device_diagnostic(raw_path, &validation_error);
    if (raw_fd < 0) {
        int error_code = validation_error != EDP_RAW_VALIDATION_OK
            ? validation_error
            : (errno != 0 ? errno : EPERM);
        fprintf(stderr, "EDP_RAW_BROKER_VALIDATION_FAILED code=%d errno=%d\n", error_code, errno);
        (void)send_broker_message(socket_fd, 1, error_code, -1);
        return 77;
    }

    int result = send_broker_message(socket_fd, 0, 0, raw_fd);
    close(raw_fd);
    return result == 0 ? 0 : 71;
}

static int receive_broker_fd(int socket_fd, int timeout_ms, int *out_error) {
    if (out_error) *out_error = 0;
    struct pollfd poll_fd = {
        .fd = socket_fd,
        .events = POLLIN,
        .revents = 0,
    };

    int poll_result;
    do {
        poll_result = poll(&poll_fd, 1, timeout_ms);
    } while (poll_result < 0 && errno == EINTR);
    if (poll_result <= 0) {
        if (out_error) *out_error = poll_result == 0 ? ETIMEDOUT : errno;
        return -1;
    }

    struct edp_raw_broker_message payload;
    memset(&payload, 0, sizeof(payload));
    struct iovec iov = {
        .iov_base = &payload,
        .iov_len = sizeof(payload),
    };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    ssize_t count;
    do {
        count = recvmsg(socket_fd, &message, 0);
    } while (count < 0 && errno == EINTR);
    if (count != (ssize_t)sizeof(payload)) {
        if (out_error) *out_error = count < 0 ? errno : EPROTO;
        return -1;
    }
    if (payload.status != 0) {
        if (out_error) *out_error = payload.error_code != 0 ? payload.error_code : EPERM;
        return -1;
    }

    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message);
         header != NULL;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
            header->cmsg_len < CMSG_LEN(sizeof(int))) continue;
        int received_fd = -1;
        memcpy(&received_fd, CMSG_DATA(header), sizeof(received_fd));
        if (received_fd < 0) break;
        int flags = fcntl(received_fd, F_GETFD);
        if (flags < 0 || fcntl(received_fd, F_SETFD, flags | FD_CLOEXEC) != 0) {
            int error_code = errno;
            close(received_fd);
            if (out_error) *out_error = error_code;
            return -1;
        }
        return received_fd;
    }

    if (out_error) *out_error = EPROTO;
    return -1;
}

int edp_raw_fd_broker_spawn(const char *app_executable, const char *raw_path, int timeout_ms, int *out_error) {
    if (out_error) *out_error = 0;
    if (geteuid() != 0 || !app_executable || !raw_path || timeout_ms <= 0 ||
        strcmp(app_executable, EDP_RAW_BROKER_APP_PATH) != 0) {
        if (out_error) *out_error = EPERM;
        return -1;
    }

    struct stat app_status;
    if (stat(app_executable, &app_status) != 0 || !S_ISREG(app_status.st_mode) ||
        app_status.st_uid != 0 || (app_status.st_mode & 0022) != 0) {
        if (out_error) *out_error = EPERM;
        return -1;
    }

    int sockets[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) != 0) {
        if (out_error) *out_error = errno;
        return -1;
    }

    posix_spawn_file_actions_t actions;
    int action_status = posix_spawn_file_actions_init(&actions);
    if (action_status != 0) {
        close(sockets[0]);
        close(sockets[1]);
        if (out_error) *out_error = action_status;
        return -1;
    }

    action_status = posix_spawn_file_actions_adddup2(&actions, sockets[1], EDP_RAW_BROKER_CHILD_SOCKET_FD);
    if (action_status == 0) action_status = posix_spawn_file_actions_addclose(&actions, sockets[0]);
    if (action_status == 0 && sockets[1] != EDP_RAW_BROKER_CHILD_SOCKET_FD) {
        action_status = posix_spawn_file_actions_addclose(&actions, sockets[1]);
    }
    if (action_status != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(sockets[0]);
        close(sockets[1]);
        if (out_error) *out_error = action_status;
        return -1;
    }

    char socket_text[16];
    snprintf(socket_text, sizeof(socket_text), "%d", EDP_RAW_BROKER_CHILD_SOCKET_FD);
    char *const argv[] = {
        (char *)app_executable,
        (char *)"--raw-fd-broker",
        socket_text,
        (char *)raw_path,
        NULL,
    };

    pid_t child_pid = -1;
    int spawn_status = posix_spawn(&child_pid, app_executable, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(sockets[1]);
    if (spawn_status != 0) {
        close(sockets[0]);
        if (out_error) *out_error = spawn_status;
        return -1;
    }

    int received_fd = receive_broker_fd(sockets[0], timeout_ms, out_error);
    close(sockets[0]);

    if (received_fd < 0) kill(child_pid, SIGKILL);
    int child_status = 0;
    while (waitpid(child_pid, &child_status, 0) < 0 && errno == EINTR) {}

    if (received_fd >= 0 && (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0)) {
        close(received_fd);
        if (out_error && *out_error == 0) *out_error = EIO;
        return -1;
    }
    return received_fd;
}
