#include <MFMount/MFMount.h>

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct async_mount_args {
    MFChannelRef channel;
    char *mountpoint;
    char *options;
    bool quiet;
};

static char *copy_string(const char *source) {
    size_t length = strlen(source) + 1;
    char *copy = malloc(length);
    if (copy != NULL) {
        memcpy(copy, source, length);
    }
    return copy;
}

static void destroy_args(struct async_mount_args *args) {
    if (args == NULL) {
        return;
    }
    if (args->channel != NULL) {
        MFRelease(args->channel);
    }
    free(args->mountpoint);
    free(args->options);
    free(args);
}

static void *mount_worker(void *opaque) {
    struct async_mount_args *args = opaque;
    errno = 0;
    MFMountResult result = MFMount(
        args->channel,
        args->mountpoint,
        args->options,
        args->quiet
    );
    int saved_errno = errno;

    fprintf(stderr,
            "DIRECT_MFMOUNT_ASYNC_RESULT=%d errno=%d options=%s\n",
            (int)result,
            saved_errno,
            args->options);

    if (result != MFMountResultSuccess) {
        (void)MFChannelClose(args->channel);
    }

    destroy_args(args);
    return NULL;
}

MFMountResult EDPAsyncMFMount(MFChannelRef channel,
                              const char *mountpoint,
                              const char *options,
                              bool quiet) {
    if (channel == NULL || mountpoint == NULL || options == NULL) {
        errno = EINVAL;
        return MFMountResultUnexpectedFailure;
    }

    struct async_mount_args *args = calloc(1, sizeof(*args));
    if (args == NULL) {
        errno = EAGAIN;
        return MFMountResultUnexpectedFailure;
    }

    args->channel = MFRetain(channel);
    args->mountpoint = copy_string(mountpoint);
    args->options = copy_string(options);
    args->quiet = quiet;
    if (args->mountpoint == NULL || args->options == NULL) {
        destroy_args(args);
        errno = EAGAIN;
        return MFMountResultUnexpectedFailure;
    }

    pthread_t thread;
    int result = pthread_create(&thread, NULL, mount_worker, args);
    if (result != 0) {
        destroy_args(args);
        errno = result;
        return MFMountResultUnexpectedFailure;
    }
    result = pthread_detach(thread);
    if (result != 0) {
        /* The worker still owns and will release args. */
        errno = result;
        return MFMountResultUnexpectedFailure;
    }

    fprintf(stderr, "DIRECT_MFMOUNT_ASYNC_STARTED=1\n");
    return MFMountResultSuccess;
}
