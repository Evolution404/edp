#include <MFMount/MFMount.h>
#include <fuse_kernel.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
extern bool EDPDirectMFMountTeardownActive(void) __attribute__((weak_import));
extern bool EDPDirectMFMountTeardownComplete(void) __attribute__((weak_import));
extern void EDPDirectMFMountMarkTransportReleased(void) __attribute__((weak_import));
#else
extern bool EDPDirectMFMountTeardownActive(void) __attribute__((weak));
extern bool EDPDirectMFMountTeardownComplete(void) __attribute__((weak));
extern void EDPDirectMFMountMarkTransportReleased(void) __attribute__((weak));
#endif

#ifndef ENOATTR
#define ENOATTR ENODATA
#endif

#define RAW_NODE_ID 2ULL
#define RAW_FILE_NAME "volume.raw"
#define DIRECT_MAX_IO (4U * 1024U * 1024U)

struct direct_state {
    int backing_fd;
    uint64_t backing_size;
    uid_t uid;
    gid_t gid;
    MFChannelRef channel;
    bool running;
};

static int send_iov(MFChannelRef channel, const struct iovec *iov, size_t count) {
    ssize_t sent = MFChannelSendMessage(channel, iov, count);
    if (sent < 0) {
        perror("MFChannelSendMessage");
        return -1;
    }
    return 0;
}

static int send_error(MFChannelRef channel, uint64_t unique, int error) {
    struct fuse_out_header out = {
        .len = (uint32_t)sizeof(out),
        .error = -error,
        .unique = unique,
    };
    const struct iovec iov[] = {
        { .iov_base = &out, .iov_len = sizeof(out) },
    };
    return send_iov(channel, iov, 1);
}

static int send_payload(MFChannelRef channel,
                        uint64_t unique,
                        const void *payload,
                        size_t payload_size) {
    if (payload_size > UINT32_MAX - sizeof(struct fuse_out_header)) {
        return send_error(channel, unique, EOVERFLOW);
    }
    struct fuse_out_header out = {
        .len = (uint32_t)(sizeof(out) + payload_size),
        .error = 0,
        .unique = unique,
    };
    if (payload_size == 0) {
        const struct iovec iov[] = {
            { .iov_base = &out, .iov_len = sizeof(out) },
        };
        return send_iov(channel, iov, 1);
    }
    const struct iovec iov[] = {
        { .iov_base = &out, .iov_len = sizeof(out) },
        { .iov_base = (void *)payload, .iov_len = payload_size },
    };
    return send_iov(channel, iov, 2);
}

static int copy_message_body(MFMessageRef message, uint8_t **bytes_out, size_t *size_out) {
    ssize_t body_size = MFMessageGetBodySize(message);
    if (body_size < (ssize_t)sizeof(struct fuse_in_header)) {
        errno = EPROTO;
        return -1;
    }

    const struct iovec *buffers = NULL;
    ssize_t count = MFMessageGetBodyBuffers(message, &buffers);
    if (count <= 0 || buffers == NULL) {
        return -1;
    }

    uint8_t *bytes = malloc((size_t)body_size);
    if (bytes == NULL) {
        return -1;
    }

    size_t copied = 0;
    for (ssize_t i = 0; i < count; i++) {
        if (buffers[i].iov_len > (size_t)body_size - copied) {
            free(bytes);
            errno = EPROTO;
            return -1;
        }
        memcpy(bytes + copied, buffers[i].iov_base, buffers[i].iov_len);
        copied += buffers[i].iov_len;
    }
    if (copied != (size_t)body_size) {
        free(bytes);
        errno = EPROTO;
        return -1;
    }

    *bytes_out = bytes;
    *size_out = copied;
    return 0;
}

static void fill_attr(const struct direct_state *state, uint64_t nodeid, struct fuse_attr *attr) {
    memset(attr, 0, sizeof(*attr));
    time_t now = time(NULL);
    attr->ino = nodeid;
    attr->uid = state->uid;
    attr->gid = state->gid;
    attr->blksize = 4096;
    attr->atime = (uint64_t)now;
    attr->mtime = (uint64_t)now;
    attr->ctime = (uint64_t)now;
#ifdef __APPLE__
    attr->btime = (uint64_t)now;
#endif

    if (nodeid == FUSE_ROOT_ID) {
        attr->mode = S_IFDIR | 0755;
        attr->nlink = 2;
        attr->size = 4096;
        attr->blocks = 8;
    } else {
        attr->mode = S_IFREG | 0600;
        attr->nlink = 1;
        attr->size = state->backing_size;
        attr->blocks = (state->backing_size + 511) / 512;
    }
}

static int send_attr(const struct direct_state *state, uint64_t unique, uint64_t nodeid) {
    if (nodeid != FUSE_ROOT_ID && nodeid != RAW_NODE_ID) {
        return send_error(state->channel, unique, ENOENT);
    }
    struct fuse_attr_out out;
    memset(&out, 0, sizeof(out));
    out.attr_valid = 1;
    fill_attr(state, nodeid, &out.attr);
    return send_payload(state->channel, unique, &out, sizeof(out));
}

static int handle_lookup(const struct direct_state *state,
                         const struct fuse_in_header *in,
                         const uint8_t *body,
                         size_t body_size) {
    if (in->nodeid != FUSE_ROOT_ID || body_size <= sizeof(*in)) {
        return send_error(state->channel, in->unique, ENOENT);
    }
    const char *name = (const char *)(body + sizeof(*in));
    size_t max_name = body_size - sizeof(*in);
    if (memchr(name, '\0', max_name) == NULL) {
        return send_error(state->channel, in->unique, EPROTO);
    }
    if (strcmp(name, RAW_FILE_NAME) != 0) {
        return send_error(state->channel, in->unique, ENOENT);
    }

    struct fuse_entry_out out;
    memset(&out, 0, sizeof(out));
    out.nodeid = RAW_NODE_ID;
    out.generation = 1;
    out.entry_valid = 1;
    out.attr_valid = 1;
    fill_attr(state, RAW_NODE_ID, &out.attr);
    return send_payload(state->channel, in->unique, &out, sizeof(out));
}

static int handle_open(const struct direct_state *state,
                       const struct fuse_in_header *in,
                       bool directory) {
    uint64_t expected = directory ? FUSE_ROOT_ID : RAW_NODE_ID;
    if (in->nodeid != expected) {
        return send_error(state->channel, in->unique, directory ? ENOTDIR : ENOENT);
    }
    struct fuse_open_out out;
    memset(&out, 0, sizeof(out));
    out.fh = expected;
    out.open_flags = directory ? 0 : FOPEN_DIRECT_IO;
    out.backing_id = -1;
    return send_payload(state->channel, in->unique, &out, sizeof(out));
}

static int handle_read(const struct direct_state *state,
                       const struct fuse_in_header *in,
                       const uint8_t *body,
                       size_t body_size) {
    if (in->nodeid != RAW_NODE_ID ||
        body_size < sizeof(*in) + sizeof(struct fuse_read_in)) {
        return send_error(state->channel, in->unique, EINVAL);
    }
    const struct fuse_read_in *request =
        (const struct fuse_read_in *)(body + sizeof(*in));
    if (request->size > DIRECT_MAX_IO) {
        return send_error(state->channel, in->unique, EINVAL);
    }
    if (request->offset >= state->backing_size) {
        return send_payload(state->channel, in->unique, NULL, 0);
    }

    size_t wanted = request->size;
    uint64_t remaining = state->backing_size - request->offset;
    if ((uint64_t)wanted > remaining) {
        wanted = (size_t)remaining;
    }
    uint8_t *data = malloc(wanted == 0 ? 1 : wanted);
    if (data == NULL) {
        return send_error(state->channel, in->unique, ENOMEM);
    }
    ssize_t count = pread(state->backing_fd, data, wanted, (off_t)request->offset);
    if (count < 0) {
        int saved = errno;
        free(data);
        return send_error(state->channel, in->unique, saved);
    }
    int result = send_payload(state->channel, in->unique, data, (size_t)count);
    free(data);
    return result;
}

static int handle_write(const struct direct_state *state,
                        const struct fuse_in_header *in,
                        const uint8_t *body,
                        size_t body_size) {
    size_t prefix = sizeof(*in) + sizeof(struct fuse_write_in);
    if (in->nodeid != RAW_NODE_ID || body_size < prefix) {
        return send_error(state->channel, in->unique, EINVAL);
    }
    const struct fuse_write_in *request =
        (const struct fuse_write_in *)(body + sizeof(*in));
    if (request->size > DIRECT_MAX_IO || body_size - prefix < request->size) {
        return send_error(state->channel, in->unique, EINVAL);
    }
    if (request->offset > state->backing_size ||
        (uint64_t)request->size > state->backing_size - request->offset) {
        return send_error(state->channel, in->unique, EFBIG);
    }

    const uint8_t *payload = body + prefix;
    size_t written = 0;
    while (written < request->size) {
        ssize_t count = pwrite(state->backing_fd,
                               payload + written,
                               request->size - written,
                               (off_t)(request->offset + written));
        if (count < 0) {
            return send_error(state->channel, in->unique, errno);
        }
        if (count == 0) {
            return send_error(state->channel, in->unique, EIO);
        }
        written += (size_t)count;
    }

    struct fuse_write_out out = {
        .size = (uint32_t)written,
        .padding = 0,
    };
    return send_payload(state->channel, in->unique, &out, sizeof(out));
}

static size_t append_dirent(uint8_t *buffer,
                            size_t capacity,
                            size_t used,
                            uint64_t ino,
                            uint64_t off,
                            uint32_t type,
                            const char *name) {
    size_t name_len = strlen(name);
    size_t record_size = FUSE_DIRENT_ALIGN(FUSE_NAME_OFFSET + name_len);
    if (record_size > capacity - used) {
        return used;
    }
    struct fuse_dirent *entry = (struct fuse_dirent *)(buffer + used);
    memset(entry, 0, record_size);
    entry->ino = ino;
    entry->off = off;
    entry->namelen = (uint32_t)name_len;
    entry->type = type;
    memcpy(entry->name, name, name_len);
    return used + record_size;
}

static int handle_readdir(const struct direct_state *state,
                          const struct fuse_in_header *in,
                          const uint8_t *body,
                          size_t body_size) {
    if (in->nodeid != FUSE_ROOT_ID ||
        body_size < sizeof(*in) + sizeof(struct fuse_read_in)) {
        return send_error(state->channel, in->unique, ENOTDIR);
    }
    const struct fuse_read_in *request =
        (const struct fuse_read_in *)(body + sizeof(*in));
    size_t capacity = request->size;
    if (capacity > 64 * 1024) {
        capacity = 64 * 1024;
    }
    uint8_t *payload = calloc(1, capacity == 0 ? 1 : capacity);
    if (payload == NULL) {
        return send_error(state->channel, in->unique, ENOMEM);
    }

    size_t used = 0;
    if (request->offset < 1) {
        used = append_dirent(payload, capacity, used, FUSE_ROOT_ID, 1, DT_DIR, ".");
    }
    if (request->offset < 2) {
        used = append_dirent(payload, capacity, used, FUSE_ROOT_ID, 2, DT_DIR, "..");
    }
    if (request->offset < 3) {
        used = append_dirent(payload, capacity, used, RAW_NODE_ID, 3, DT_REG, RAW_FILE_NAME);
    }

    int result = send_payload(state->channel, in->unique, payload, used);
    free(payload);
    return result;
}

static int handle_statfs(const struct direct_state *state, uint64_t unique) {
    struct fuse_statfs_out out;
    memset(&out, 0, sizeof(out));
    out.st.bsize = 4096;
    out.st.frsize = 4096;
    out.st.blocks = (state->backing_size + 4095) / 4096;
    out.st.bfree = 0;
    out.st.bavail = 0;
    out.st.files = 2;
    out.st.ffree = 0;
    out.st.namelen = 255;
    return send_payload(state->channel, unique, &out, sizeof(out));
}

static int handle_init(const struct direct_state *state,
                       const struct fuse_in_header *in,
                       const uint8_t *body,
                       size_t body_size) {
    struct init_compat {
        uint32_t major;
        uint32_t minor;
        uint32_t max_readahead;
        uint32_t flags;
    };
    if (body_size < sizeof(*in) + sizeof(struct init_compat)) {
        return send_error(state->channel, in->unique, EPROTO);
    }
    const struct init_compat *request =
        (const struct init_compat *)(body + sizeof(*in));
    fprintf(stderr,
            "DIRECT_INIT_IN major=%u minor=%u max_readahead=%u flags=0x%08x\n",
            request->major,
            request->minor,
            request->max_readahead,
            request->flags);

    if (request->major != FUSE_KERNEL_VERSION) {
        struct fuse_init_out mismatch;
        memset(&mismatch, 0, sizeof(mismatch));
        mismatch.major = FUSE_KERNEL_VERSION;
        mismatch.minor = FUSE_KERNEL_MINOR_VERSION;
        return send_payload(state->channel, in->unique, &mismatch, FUSE_COMPAT_INIT_OUT_SIZE);
    }

    struct fuse_init_out out;
    memset(&out, 0, sizeof(out));
    out.major = FUSE_KERNEL_VERSION;
    out.minor = request->minor < 19 ? request->minor : 19;
    out.max_readahead = request->max_readahead;
#ifdef __APPLE__
    out.flags = request->flags & FUSE_DARWIN_PAYLOAD_BUF;
#else
    out.flags = request->flags & FUSE_BIG_WRITES;
#endif
    out.max_write = DIRECT_MAX_IO;

    fprintf(stderr,
            "DIRECT_INIT_OUT major=%u minor=%u max_write=%u flags=0x%08x\n",
            out.major,
            out.minor,
            out.max_write,
            out.flags);
    return send_payload(state->channel,
                        in->unique,
                        &out,
                        FUSE_COMPAT_22_INIT_OUT_SIZE);
}

static int handle_getxattr(const struct direct_state *state,
                           const struct fuse_in_header *in) {
    return send_error(state->channel, in->unique, ENOATTR);
}

static int handle_listxattr(const struct direct_state *state,
                            const struct fuse_in_header *in,
                            const uint8_t *body,
                            size_t body_size) {
    if (body_size < sizeof(*in) + sizeof(struct fuse_getxattr_in)) {
        return send_error(state->channel, in->unique, EINVAL);
    }
    const struct fuse_getxattr_in *request =
        (const struct fuse_getxattr_in *)(body + sizeof(*in));
    if (request->size == 0) {
        struct fuse_getxattr_out out = { .size = 0, .padding = 0 };
        return send_payload(state->channel, in->unique, &out, sizeof(out));
    }
    return send_payload(state->channel, in->unique, NULL, 0);
}

static int handle_setattr(const struct direct_state *state,
                          const struct fuse_in_header *in,
                          const uint8_t *body,
                          size_t body_size) {
    if (body_size < sizeof(*in) + sizeof(struct fuse_setattr_in)) {
        return send_error(state->channel, in->unique, EINVAL);
    }
    const struct fuse_setattr_in *request =
        (const struct fuse_setattr_in *)(body + sizeof(*in));
    if ((request->valid & FATTR_SIZE) != 0 &&
        (in->nodeid != RAW_NODE_ID || request->size != state->backing_size)) {
        return send_error(state->channel, in->unique, EPERM);
    }
    return send_attr(state, in->unique, in->nodeid);
}

static int dispatch_message(struct direct_state *state, MFMessageRef message) {
    uint8_t *body = NULL;
    size_t body_size = 0;
    if (copy_message_body(message, &body, &body_size) != 0) {
        perror("copy_message_body");
        return -1;
    }

    const struct fuse_in_header *in = (const struct fuse_in_header *)body;
    fprintf(stderr,
            "DIRECT_OPCODE opcode=%u unique=%" PRIu64 " node=%" PRIu64 " len=%u body=%zu\n",
            in->opcode,
            in->unique,
            in->nodeid,
            in->len,
            body_size);

    int result = 0;
    switch (in->opcode) {
        case FUSE_INIT:
            result = handle_init(state, in, body, body_size);
            break;
        case FUSE_LOOKUP:
            result = handle_lookup(state, in, body, body_size);
            break;
        case FUSE_GETATTR:
            result = send_attr(state, in->unique, in->nodeid);
            break;
        case FUSE_SETATTR:
            result = handle_setattr(state, in, body, body_size);
            break;
        case FUSE_OPEN:
            result = handle_open(state, in, false);
            break;
        case FUSE_READ:
            result = handle_read(state, in, body, body_size);
            break;
        case FUSE_WRITE:
            result = handle_write(state, in, body, body_size);
            break;
        case FUSE_STATFS:
            result = handle_statfs(state, in->unique);
            break;
        case FUSE_RELEASE:
            result = send_payload(state->channel, in->unique, NULL, 0);
            break;
        case FUSE_FSYNC:
            if (fsync(state->backing_fd) != 0) {
                result = send_error(state->channel, in->unique, errno);
            } else {
                result = send_payload(state->channel, in->unique, NULL, 0);
            }
            break;
        case FUSE_FLUSH:
            if (fsync(state->backing_fd) != 0) {
                result = send_error(state->channel, in->unique, errno);
            } else {
                result = send_payload(state->channel, in->unique, NULL, 0);
            }
            break;
        case FUSE_OPENDIR:
            result = handle_open(state, in, true);
            break;
        case FUSE_READDIR:
            result = handle_readdir(state, in, body, body_size);
            break;
        case FUSE_RELEASEDIR:
        case FUSE_FSYNCDIR:
            result = send_payload(state->channel, in->unique, NULL, 0);
            break;
        case FUSE_ACCESS:
            if (in->nodeid == FUSE_ROOT_ID || in->nodeid == RAW_NODE_ID) {
                result = send_payload(state->channel, in->unique, NULL, 0);
            } else {
                result = send_error(state->channel, in->unique, ENOENT);
            }
            break;
        case FUSE_GETXATTR:
            result = handle_getxattr(state, in);
            break;
        case FUSE_LISTXATTR:
            result = handle_listxattr(state, in, body, body_size);
            break;
        case FUSE_FORGET:
        case FUSE_BATCH_FORGET:
            result = 0;
            break;
        case FUSE_DESTROY:
            if (EDPDirectMFMountTeardownActive != NULL &&
                EDPDirectMFMountTeardownActive()) {
                fprintf(stderr, "DIRECT_MFMOUNT_DESTROY_DEFERRED=1\n");
            } else {
                state->running = false;
            }
            result = 0;
            break;
        case FUSE_MKDIR:
        case FUSE_MKNOD:
        case FUSE_CREATE:
        case FUSE_UNLINK:
        case FUSE_RMDIR:
        case FUSE_RENAME:
        case FUSE_RENAME2:
        case FUSE_LINK:
        case FUSE_SYMLINK:
        case FUSE_SETXATTR:
        case FUSE_REMOVEXATTR:
            result = send_error(state->channel, in->unique, EROFS);
            break;
        default:
            result = send_error(state->channel, in->unique, ENOSYS);
            break;
    }

    free(body);
    return result;
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s <backing-file> <mountpoint> [volume-name]\n", argv[0]);
        return 64;
    }

    const char *backing_path = argv[1];
    const char *mountpoint = argv[2];
    const char *volume_name = argc == 4 ? argv[3] : "EDP Direct MFMount";

    int backing_fd = open(backing_path, O_RDWR);
    if (backing_fd < 0) {
        perror("open backing");
        return 1;
    }
    struct stat st;
    if (fstat(backing_fd, &st) != 0 || st.st_size < 0) {
        perror("fstat backing");
        close(backing_fd);
        return 1;
    }

    MFChannelRef channel = MFChannelCreate();
    if (channel == NULL) {
        fprintf(stderr, "MFChannelCreate failed\n");
        close(backing_fd);
        return 1;
    }

    char options[512];
    int option_length = snprintf(options,
                                 sizeof(options),
                                 "nobrowse,volname=%s",
                                 volume_name);
    if (option_length < 0 || (size_t)option_length >= sizeof(options)) {
        fprintf(stderr, "volume name too long\n");
        MFRelease(channel);
        close(backing_fd);
        return 64;
    }

    errno = 0;
    MFMountResult mount_result = MFMount(channel, mountpoint, options, true);
    int mount_errno = errno;
    fprintf(stderr,
            "DIRECT_MFMOUNT_RESULT=%d errno=%d options=%s\n",
            (int)mount_result,
            mount_errno,
            options);
    if (mount_result != MFMountResultSuccess) {
        MFChannelClose(channel);
        MFRelease(channel);
        close(backing_fd);
        return 2;
    }

    struct direct_state state = {
        .backing_fd = backing_fd,
        .backing_size = (uint64_t)st.st_size,
        .uid = getuid(),
        .gid = getgid(),
        .channel = channel,
        .running = true,
    };
    fprintf(stderr,
            "DIRECT_MFMOUNT_STARTED size=%" PRIu64 " mountpoint=%s\n",
            state.backing_size,
            mountpoint);

    int exit_code = 0;
    while (state.running) {
        MFMessageRef message = MFChannelCopyNextMessage(channel);
        if (message == NULL) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == ENODEV) {
                break;
            }
            perror("MFChannelCopyNextMessage");
            exit_code = 3;
            break;
        }
        if (dispatch_message(&state, message) != 0) {
            exit_code = 4;
            MFRelease(message);
            break;
        }
        MFRelease(message);
    }

    bool lifecycle_teardown = EDPDirectMFMountTeardownActive != NULL &&
        EDPDirectMFMountTeardownComplete != NULL &&
        EDPDirectMFMountMarkTransportReleased != NULL &&
        EDPDirectMFMountTeardownActive();

    if (fsync(backing_fd) != 0) {
        perror("fsync backing");
    }

    if (lifecycle_teardown) {
        /* The signal worker already closed the channel.  Drop the server's
         * final channel ownership before it asks DA to eject the virtual
         * disk, then stay alive only to report the completed gate. */
        MFRelease(channel);
        close(backing_fd);
        EDPDirectMFMountMarkTransportReleased();
        fprintf(stderr, "DIRECT_MFMOUNT_SERVER_TRANSPORT_RELEASED=1\n");

        struct timespec delay = {
            .tv_sec = 0,
            .tv_nsec = 100 * 1000 * 1000,
        };
        for (int attempt = 0; attempt < 600; attempt++) {
            if (EDPDirectMFMountTeardownComplete()) {
                break;
            }
            nanosleep(&delay, NULL);
        }
        fprintf(stderr,
                "DIRECT_MFMOUNT_TEARDOWN_COMPLETE=%d\n",
                EDPDirectMFMountTeardownComplete() ? 1 : 0);
    } else {
        MFChannelClose(channel);
        MFRelease(channel);
        close(backing_fd);
    }
    fprintf(stderr, "DIRECT_MFMOUNT_EXIT=%d\n", exit_code);
    return exit_code;
}
