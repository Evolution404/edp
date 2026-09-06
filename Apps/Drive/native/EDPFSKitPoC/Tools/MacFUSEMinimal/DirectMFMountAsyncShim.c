#include <MFMount/MFMount.h>

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct async_mount_args {
    MFChannelRef channel;
    char *mountpoint;
    char *options;
    bool quiet;
};

struct termination_wait_args {
    MFChannelRef channel;
    char *mountpoint;
    sigset_t signals;
};

extern void EDPDirectMFMountSignalReady(void);

static atomic_bool g_teardown_active = false;
static atomic_bool g_transport_released = false;

bool EDPDirectMFMountTeardownActive(void) {
    return atomic_load_explicit(&g_teardown_active, memory_order_acquire);
}

void EDPDirectMFMountMarkTransportReleased(void) {
    atomic_store_explicit(&g_transport_released, true, memory_order_release);
}

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

static void destroy_termination_args(struct termination_wait_args *args) {
    if (args == NULL) {
        return;
    }
    if (args->channel != NULL) {
        MFRelease(args->channel);
    }
    free(args->mountpoint);
    free(args);
}

static bool wait_for_transport_release(void) {
    struct timespec delay = {
        .tv_sec = 0,
        .tv_nsec = 100 * 1000 * 1000,
    };
    for (int attempt = 0; attempt < 100; attempt++) {
        if (atomic_load_explicit(&g_transport_released,
                                 memory_order_acquire)) {
            return true;
        }
        nanosleep(&delay, NULL);
    }
    return false;
}

static void *termination_wait_worker(void *opaque) {
    struct termination_wait_args *args = opaque;
    int signal_number = 0;
    int wait_result = sigwait(&args->signals, &signal_number);
    if (wait_result != 0) {
        fprintf(stderr,
                "DIRECT_MFMOUNT_SIGWAIT_FAILED=%d\n",
                wait_result);
        destroy_termination_args(args);
        return NULL;
    }

    /* MFMount owns this Local volume. Per the public MFMount contract, channel
     * lifetime is the mount lifetime: wake the receive loop, let the server
     * close its own channel, and never reach into Disk Arbitration or macFUSE's
     * private XPC implementation from this transport process. */
    atomic_store_explicit(&g_teardown_active, true, memory_order_release);
    atomic_store_explicit(&g_transport_released, false, memory_order_release);
    fprintf(stderr,
            "DIRECT_MFMOUNT_TERMINATION_SIGNAL=%d mountpoint=%s\n",
            signal_number,
            args->mountpoint);

    errno = 0;
    bool interrupted = MFChannelInterrupt(args->channel);
    int interrupt_errno = errno;
    fprintf(stderr,
            "DIRECT_MFMOUNT_CHANNEL_INTERRUPT_RESULT=%d errno=%d mountpoint=%s\n",
            interrupted ? 1 : 0,
            interrupt_errno,
            args->mountpoint);
    if (!interrupted) {
        atomic_store_explicit(&g_teardown_active, false, memory_order_release);
        destroy_termination_args(args);
        return NULL;
    }

    bool transport_released = wait_for_transport_release();
    fprintf(stderr,
            "DIRECT_MFMOUNT_TRANSPORT_RELEASED=%d mountpoint=%s\n",
            transport_released ? 1 : 0,
            args->mountpoint);
    atomic_store_explicit(&g_teardown_active, false, memory_order_release);
    destroy_termination_args(args);
    return NULL;
}

static int start_termination_waiter(MFChannelRef channel,
                                    const char *mountpoint) {
    sigset_t signals;
    if (sigemptyset(&signals) != 0 ||
        sigaddset(&signals, SIGTERM) != 0 ||
        sigaddset(&signals, SIGINT) != 0) {
        return errno == 0 ? EINVAL : errno;
    }

    int result = pthread_sigmask(SIG_BLOCK, &signals, NULL);
    if (result != 0) {
        return result;
    }

    struct termination_wait_args *args = calloc(1, sizeof(*args));
    if (args == NULL) {
        return EAGAIN;
    }
    args->channel = MFRetain(channel);
    args->mountpoint = copy_string(mountpoint);
    args->signals = signals;
    if (args->mountpoint == NULL) {
        destroy_termination_args(args);
        return EAGAIN;
    }

    pthread_t thread;
    result = pthread_create(&thread, NULL, termination_wait_worker, args);
    if (result != 0) {
        destroy_termination_args(args);
        return result;
    }
    result = pthread_detach(thread);
    if (result != 0) {
        /* The waiter still owns and will release args. */
        return result;
    }
    return 0;
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
    } else {
        /* EDPAsyncMFMount returns immediately after spawning this worker, so
         * only the real framework MFMount completion here is authoritative for
         * filesystem readiness.  Signal the parent now; FUSE INIT alone can
         * still precede the Local mount becoming usable at volume.raw. */
        EDPDirectMFMountSignalReady();
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

    int termination_result = start_termination_waiter(channel, mountpoint);
    if (termination_result != 0) {
        errno = termination_result;
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
