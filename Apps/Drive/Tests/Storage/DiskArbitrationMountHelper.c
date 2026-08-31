#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

typedef struct {
    bool done;
    DAReturn status;
} EDPDAContext;

static void edp_da_callback(DADiskRef disk, DADissenterRef dissenter, void *context) {
    (void)disk;
    EDPDAContext *state = context;
    state->status = dissenter ? DADissenterGetStatus(dissenter) : kDAReturnSuccess;
    state->done = true;
}

static bool wait_for_callback(EDPDAContext *state, CFTimeInterval timeout) {
    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (!state->done && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    return state->done;
}

static bool mountpoint_for_source(const char *source, char *output, size_t output_size) {
    struct statfs *mounts = NULL;
    const int count = getmntinfo(&mounts, MNT_NOWAIT);
    if (count <= 0 || mounts == NULL) {
        return false;
    }
    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_mntfromname, source) != 0) {
            continue;
        }
        if (strlcpy(output, mounts[index].f_mntonname, output_size) >= output_size) {
            return false;
        }
        return true;
    }
    return false;
}

static bool wait_for_mount_state(const char *source, bool mounted, char *output, size_t output_size) {
    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5.0;
    do {
        char current[PATH_MAX] = {0};
        const bool present = mountpoint_for_source(source, current, sizeof(current));
        if (present == mounted) {
            if (mounted && output != NULL && output_size > 0) {
                if (strlcpy(output, current, output_size) >= output_size) {
                    return false;
                }
            }
            return true;
        }
        usleep(50000);
    } while (CFAbsoluteTimeGetCurrent() < deadline);
    return false;
}

static int run_mount(DASessionRef session, DADiskRef disk, const char *source, const char *mountpoint, bool read_only) {
    EDPDAContext state = {.done = false, .status = kDAReturnError};
    CFURLRef mount_url = NULL;
    if (mountpoint != NULL) {
        mount_url = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault,
            (const UInt8 *)mountpoint,
            (CFIndex)strlen(mountpoint),
            true
        );
        if (mount_url == NULL) {
            fprintf(stderr, "failed to create mountpoint URL\n");
            return 2;
        }
    }

    if (read_only) {
        CFStringRef arguments[] = {CFSTR("rdonly"), NULL};
        DADiskMountWithArguments(
            disk,
            mount_url,
            kDADiskMountOptionDefault,
            edp_da_callback,
            &state,
            arguments
        );
    } else {
        DADiskMount(disk, mount_url, kDADiskMountOptionDefault, edp_da_callback, &state);
    }

    if (mount_url != NULL) {
        CFRelease(mount_url);
    }
    if (!wait_for_callback(&state, 20.0)) {
        fprintf(stderr, "Disk Arbitration mount callback timed out\n");
        return 124;
    }
    if (state.status != kDAReturnSuccess) {
        fprintf(stderr, "Disk Arbitration mount failed: 0x%08x\n", state.status);
        return 1;
    }

    char resolved[PATH_MAX] = {0};
    if (!wait_for_mount_state(source, true, resolved, sizeof(resolved))) {
        fprintf(stderr, "Disk Arbitration reported mount success but NOWAIT mount table did not converge\n");
        return 1;
    }
    printf("DA_MOUNTPOINT=%s\n", resolved);
    printf("RESULT=DISK_ARBITRATION_MOUNT_OK\n");
    (void)session;
    return 0;
}

static int run_unmount(DASessionRef session, DADiskRef disk, const char *source) {
    EDPDAContext state = {.done = false, .status = kDAReturnError};
    DADiskUnmount(disk, kDADiskUnmountOptionDefault, edp_da_callback, &state);
    if (!wait_for_callback(&state, 20.0)) {
        fprintf(stderr, "Disk Arbitration unmount callback timed out\n");
        return 124;
    }
    if (state.status != kDAReturnSuccess && state.status != kDAReturnNotMounted) {
        fprintf(stderr, "Disk Arbitration unmount failed: 0x%08x\n", state.status);
        return 1;
    }
    if (!wait_for_mount_state(source, false, NULL, 0)) {
        fprintf(stderr, "Disk Arbitration reported unmount success but NOWAIT mount table still contains source\n");
        return 1;
    }
    printf("RESULT=DISK_ARBITRATION_UNMOUNT_OK\n");
    (void)session;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s --mount BSD | --mount-readonly-at BSD MOUNTPOINT | --unmount BSD\n", argv[0]);
        return 64;
    }

    const char *operation = argv[1];
    const char *bsd = argv[2];
    if (strncmp(bsd, "disk", 4) != 0) {
        fprintf(stderr, "invalid BSD name\n");
        return 64;
    }

    char source[PATH_MAX] = {0};
    if (snprintf(source, sizeof(source), "/dev/%s", bsd) >= (int)sizeof(source)) {
        fprintf(stderr, "BSD path too long\n");
        return 64;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (session == NULL) {
        fprintf(stderr, "failed to create Disk Arbitration session\n");
        return 2;
    }
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, source);
    if (disk == NULL) {
        fprintf(stderr, "failed to create Disk Arbitration disk for %s\n", source);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return 2;
    }

    int result = 64;
    if (strcmp(operation, "--mount") == 0 && argc == 3) {
        result = run_mount(session, disk, source, NULL, false);
    } else if (strcmp(operation, "--mount-readonly-at") == 0 && argc == 4) {
        result = run_mount(session, disk, source, argv[3], true);
    } else if (strcmp(operation, "--unmount") == 0 && argc == 3) {
        result = run_unmount(session, disk, source);
    } else {
        fprintf(stderr, "invalid arguments\n");
    }

    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);
    return result;
}
