#include <MFMount/MFMount.h>
#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <xpc/xpc.h>

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
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

struct da_unmount_context {
    bool completed;
    DAReturn status;
};

static atomic_bool g_teardown_active = false;
static atomic_bool g_teardown_complete = false;
static atomic_bool g_transport_released = false;

bool EDPDirectMFMountTeardownActive(void) {
    return atomic_load_explicit(&g_teardown_active, memory_order_acquire);
}

bool EDPDirectMFMountTeardownComplete(void) {
    return atomic_load_explicit(&g_teardown_complete, memory_order_acquire);
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

static int copy_mount_source(const char *mountpoint,
                             char *source,
                             size_t source_size) {
    struct statfs *mounts = NULL;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    if (count <= 0) {
        return errno == 0 ? EIO : errno;
    }

    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_mntonname, mountpoint) != 0) {
            continue;
        }
        const char *candidate = mounts[index].f_mntfromname;
        if (strncmp(candidate, "/dev/disk", strlen("/dev/disk")) != 0) {
            return ENODEV;
        }
        int length = snprintf(source, source_size, "%s", candidate);
        if (length < 0 || (size_t)length >= source_size) {
            return ENAMETOOLONG;
        }
        return 0;
    }
    return ENOENT;
}

static bool mount_source_is_present(const char *mountpoint,
                                    const char *source) {
    struct statfs *mounts = NULL;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    if (count <= 0) {
        return true;
    }
    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_mntonname, mountpoint) == 0 ||
            strcmp(mounts[index].f_mntfromname, source) == 0) {
            return true;
        }
    }
    return false;
}

static void da_operation_callback(DADiskRef disk,
                                  DADissenterRef dissenter,
                                  void *opaque) {
    (void)disk;
    struct da_unmount_context *context = opaque;
    context->status = dissenter == NULL
        ? kDAReturnSuccess
        : DADissenterGetStatus(dissenter);
    context->completed = true;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static bool wait_for_da_operation(struct da_unmount_context *context) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 30.0;
    while (!context->completed) {
        CFTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0.0) {
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                           remaining < 1.0 ? remaining : 1.0,
                           true);
    }
    return context->completed;
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

static int deactivate_source_with_macfuse_daemon(const char *bsd_name) {
    static const char *service_names[] = {
        "3T5GSNBU6W.io.macfuse.app.launchservice.daemon.xpc",
        "io.macfuse.mount",
    };

    for (size_t index = 0;
         index < sizeof(service_names) / sizeof(service_names[0]);
         index++) {
        const char *service_name = service_names[index];
        xpc_connection_t connection = xpc_connection_create_mach_service(
            service_name,
            NULL,
            XPC_CONNECTION_MACH_SERVICE_PRIVILEGED
        );
        if (connection == NULL) {
            continue;
        }
        xpc_connection_set_event_handler(
            connection,
            ^(xpc_object_t event) { (void)event; }
        );
        xpc_connection_activate(connection);

        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        xpc_object_t input = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(message, "method", "device/deactivate");
        xpc_dictionary_set_string(input, "bsdName", bsd_name);
        xpc_dictionary_set_value(message, "input", input);

        fprintf(stderr,
                "DIRECT_MFMOUNT_MACFUSE_DEACTIVATE_REQUESTED=1 "
                "service=%s bsd=%s\n",
                service_name,
                bsd_name);
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
            connection,
            message
        );
        char *description = reply == NULL
            ? NULL
            : xpc_copy_description(reply);
        fprintf(stderr,
                "DIRECT_MFMOUNT_MACFUSE_DEACTIVATE_REPLY=%s "
                "service=%s bsd=%s\n",
                description == NULL ? "<null>" : description,
                service_name,
                bsd_name);

        bool succeeded = reply != NULL &&
            xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
            xpc_dictionary_get_value(reply, "output") != NULL &&
            xpc_dictionary_get_value(reply, "error") == NULL;

        free(description);
        if (reply != NULL) {
            xpc_release(reply);
        }
        xpc_release(input);
        xpc_release(message);
        xpc_connection_cancel(connection);
        xpc_release(connection);

        if (succeeded) {
            fprintf(stderr,
                    "DIRECT_MFMOUNT_MACFUSE_DEACTIVATION_STATUS=0 "
                    "service=%s bsd=%s\n",
                    service_name,
                    bsd_name);
            return 0;
        }
    }

    fprintf(stderr,
            "DIRECT_MFMOUNT_MACFUSE_DEACTIVATION_STATUS=%d bsd=%s\n",
            EIO,
            bsd_name);
    return EIO;
}

static int unmount_source_with_disk_arbitration(const char *source,
                                                const char *mountpoint,
                                                MFChannelRef *channel) {
    const char *expected_bsd_name = source + strlen("/dev/");
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (session == NULL) {
        return ENOMEM;
    }

    CFRunLoopRef run_loop = CFRunLoopGetCurrent();
    DASessionScheduleWithRunLoop(session, run_loop, kCFRunLoopDefaultMode);
    CFURLRef volume_url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)mountpoint,
        strlen(mountpoint),
        true
    );
    if (volume_url == NULL) {
        DASessionUnscheduleFromRunLoop(session, run_loop,
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return ENOMEM;
    }
    DADiskRef disk = DADiskCreateFromVolumePath(
        kCFAllocatorDefault,
        session,
        volume_url
    );
    CFRelease(volume_url);
    if (disk == NULL) {
        DASessionUnscheduleFromRunLoop(session, run_loop,
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return ENODEV;
    }
    const char *actual_bsd_name = DADiskGetBSDName(disk);
    if (actual_bsd_name == NULL ||
        strcmp(actual_bsd_name, expected_bsd_name) != 0) {
        fprintf(stderr,
                "DIRECT_MFMOUNT_DA_SOURCE_MISMATCH=1 expected=%s actual=%s\n",
                expected_bsd_name,
                actual_bsd_name == NULL ? "<null>" : actual_bsd_name);
        DASessionUnscheduleFromRunLoop(session, run_loop,
                                       kCFRunLoopDefaultMode);
        CFRelease(disk);
        CFRelease(session);
        return EXDEV;
    }
    fprintf(stderr,
            "DIRECT_MFMOUNT_DA_VOLUME_MATCH=1 source=%s bsd=%s mountpoint=%s\n",
            source,
            actual_bsd_name,
            mountpoint);

    struct da_unmount_context context = {
        .completed = false,
        .status = kDAReturnError,
    };
    fprintf(stderr,
            "DIRECT_MFMOUNT_DA_UNMOUNT_REQUESTED=1 source=%s whole=1\n",
            source);
    DADiskUnmount(disk,
                  kDADiskUnmountOptionWhole,
                  da_operation_callback,
                  &context);

    if (!wait_for_da_operation(&context)) {
        fprintf(stderr,
                "DIRECT_MFMOUNT_DA_UNMOUNT_TIMEOUT=1 source=%s\n",
                source);
        context.status = kDAReturnError;
    }
    fprintf(stderr,
            "DIRECT_MFMOUNT_DA_UNMOUNT_STATUS=%#x source=%s\n",
            (unsigned int)context.status,
            source);

    if (context.status != kDAReturnSuccess &&
        context.status != kDAReturnNotMounted) {
        DASessionUnscheduleFromRunLoop(session, run_loop,
                                       kCFRunLoopDefaultMode);
        CFRelease(disk);
        CFRelease(session);
        fprintf(stderr,
                "DIRECT_MFMOUNT_DA_DEACTIVATION_STATUS=%#x source=%s\n",
                (unsigned int)context.status,
                source);
        return EBUSY;
    }

    /* A Local FSKit virtual disk remains busy while the MFMount XPC transport
     * is live.  Keep the DADiskRef/session alive, close the transport after
     * the whole-disk unmount acknowledgement, then deactivate that same
     * virtual disk with DADiskEject. */
    errno = 0;
    bool closed = MFChannelClose(*channel);
    int saved_errno = errno;
    fprintf(stderr,
            "DIRECT_MFMOUNT_CHANNEL_CLOSE_RESULT=%d errno=%d\n",
            closed ? 1 : 0,
            saved_errno);
    if (!closed) {
        DASessionUnscheduleFromRunLoop(session, run_loop,
                                       kCFRunLoopDefaultMode);
        CFRelease(disk);
        CFRelease(session);
        return saved_errno == 0 ? EIO : saved_errno;
    }

    MFRelease(*channel);
    *channel = NULL;
    bool transport_released = wait_for_transport_release();
    fprintf(stderr,
            "DIRECT_MFMOUNT_TRANSPORT_RELEASED=%d source=%s\n",
            transport_released ? 1 : 0,
            source);
    if (!transport_released) {
        DASessionUnscheduleFromRunLoop(session, run_loop,
                                       kCFRunLoopDefaultMode);
        CFRelease(disk);
        CFRelease(session);
        return ETIMEDOUT;
    }

    if (mount_source_is_present(mountpoint, source) &&
        deactivate_source_with_macfuse_daemon(expected_bsd_name) == 0) {
        context.completed = true;
        context.status = kDAReturnSuccess;
    }

    if (mount_source_is_present(mountpoint, source)) {
        context.completed = false;
        context.status = kDAReturnError;
        fprintf(stderr,
                "DIRECT_MFMOUNT_DA_EJECT_REQUESTED=1 source=%s\n",
                source);
        DADiskEject(disk,
                    kDADiskEjectOptionDefault,
                    da_operation_callback,
                    &context);
        if (!wait_for_da_operation(&context)) {
            fprintf(stderr,
                    "DIRECT_MFMOUNT_DA_EJECT_TIMEOUT=1 source=%s\n",
                    source);
            context.status = kDAReturnError;
        }
        fprintf(stderr,
                "DIRECT_MFMOUNT_DA_EJECT_STATUS=%#x source=%s\n",
                (unsigned int)context.status,
                source);
    }

    DASessionUnscheduleFromRunLoop(session, run_loop, kCFRunLoopDefaultMode);
    CFRelease(disk);
    CFRelease(session);

    fprintf(stderr,
            "DIRECT_MFMOUNT_DA_DEACTIVATION_STATUS=%#x source=%s\n",
            (unsigned int)context.status,
            source);
    return context.status == kDAReturnSuccess ||
           context.status == kDAReturnNotMounted ? 0 : EBUSY;
}

static bool wait_for_mount_table_removal(const char *mountpoint,
                                         const char *source) {
    struct timespec delay = {
        .tv_sec = 0,
        .tv_nsec = 100 * 1000 * 1000,
    };
    for (int attempt = 0; attempt < 100; attempt++) {
        if (!mount_source_is_present(mountpoint, source)) {
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

    char source[PATH_MAX];
    int source_result = copy_mount_source(
        args->mountpoint,
        source,
        sizeof(source)
    );
    if (source_result != 0) {
        fprintf(stderr,
                "DIRECT_MFMOUNT_SOURCE_FAILED=%d mountpoint=%s\n",
                source_result,
                args->mountpoint);
        destroy_termination_args(args);
        return NULL;
    }
    fprintf(stderr,
            "DIRECT_MFMOUNT_SOURCE=%s mountpoint=%s\n",
            source,
            args->mountpoint);

    /* Keep the server process alive while Disk Arbitration acknowledges the
     * whole source, close its transport, and deactivate that exact source. */
    atomic_store_explicit(&g_teardown_active, true, memory_order_release);
    atomic_store_explicit(&g_teardown_complete, false, memory_order_release);
    atomic_store_explicit(&g_transport_released, false, memory_order_release);
    fprintf(stderr,
            "DIRECT_MFMOUNT_TERMINATION_SIGNAL=%d\n",
            signal_number);
    int unmount_result = unmount_source_with_disk_arbitration(
        source,
        args->mountpoint,
        &args->channel
    );
    if (unmount_result != 0) {
        atomic_store_explicit(&g_teardown_complete, true,
                              memory_order_release);
        atomic_store_explicit(&g_teardown_active, false, memory_order_release);
        fprintf(stderr,
                "DIRECT_MFMOUNT_DA_UNMOUNT_FAILED=%d source=%s\n",
                unmount_result,
                source);
        destroy_termination_args(args);
        return NULL;
    }

    bool mount_gone = wait_for_mount_table_removal(args->mountpoint, source);
    fprintf(stderr,
            "DIRECT_MFMOUNT_MOUNT_TABLE_GONE=%d source=%s mountpoint=%s\n",
            mount_gone ? 1 : 0,
            source,
            args->mountpoint);
    atomic_store_explicit(&g_teardown_complete, true, memory_order_release);

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
