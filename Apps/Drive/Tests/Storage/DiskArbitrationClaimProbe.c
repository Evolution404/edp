#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    bool done;
    DAReturn status;
} ClaimContext;

static void claim_callback(DADiskRef disk, DADissenterRef dissenter, void *context) {
    (void)disk;
    ClaimContext *state = context;
    state->status = dissenter ? DADissenterGetStatus(dissenter) : kDAReturnSuccess;
    state->done = true;
}

static DADissenterRef claim_release_callback(DADiskRef disk, void *context) {
    (void)disk;
    (void)context;
    return DADissenterCreate(
        kCFAllocatorDefault,
        kDAReturnNotPermitted,
        CFSTR("EDP claim probe is holding the exact test generation")
    );
}

static bool wait_for_claim(ClaimContext *state, CFTimeInterval timeout) {
    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (!state->done && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    return state->done;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s diskN expected-registry-id hold-seconds\n", argv[0]);
        return 64;
    }
    if (strncmp(argv[1], "disk", 4) != 0) {
        fprintf(stderr, "invalid BSD name\n");
        return 64;
    }
    char *end = NULL;
    const unsigned long long expected = strtoull(argv[2], &end, 0);
    if (!end || *end != '\0' || expected == 0) {
        fprintf(stderr, "invalid registry id\n");
        return 64;
    }
    end = NULL;
    const long hold_seconds = strtol(argv[3], &end, 10);
    if (!end || *end != '\0' || hold_seconds < 1 || hold_seconds > 30) {
        fprintf(stderr, "invalid hold seconds\n");
        return 64;
    }

    char path[128];
    if (snprintf(path, sizeof(path), "/dev/%s", argv[1]) >= (int)sizeof(path)) {
        return 64;
    }
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) {
        fprintf(stderr, "DASessionCreate failed\n");
        return 2;
    }
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, path);
    if (!disk) {
        fprintf(stderr, "DADiskCreateFromBSDName failed\n");
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return 2;
    }

    io_service_t media = DADiskCopyIOMedia(disk);
    if (media == IO_OBJECT_NULL) {
        fprintf(stderr, "DADiskCopyIOMedia failed\n");
        CFRelease(disk);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return 2;
    }
    uint64_t actual = 0;
    const kern_return_t kr = IORegistryEntryGetRegistryEntryID(media, &actual);
    IOObjectRelease(media);
    if (kr != KERN_SUCCESS || actual != (uint64_t)expected) {
        fprintf(stderr, "registry identity mismatch expected=%llu actual=%llu\n", expected, (unsigned long long)actual);
        CFRelease(disk);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return 77;
    }

    ClaimContext state = {.done = false, .status = kDAReturnError};
    DADiskClaim(
        disk,
        kDADiskClaimOptionDefault,
        claim_release_callback,
        NULL,
        claim_callback,
        &state
    );
    if (!wait_for_claim(&state, 10.0)) {
        fprintf(stderr, "DADiskClaim callback timed out\n");
        CFRelease(disk);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return 124;
    }
    if (state.status != kDAReturnSuccess || !DADiskIsClaimed(disk)) {
        fprintf(stderr, "DADiskClaim failed status=0x%08x claimed=%d\n", state.status, DADiskIsClaimed(disk));
        CFRelease(disk);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return 1;
    }

    printf("CLAIM_BSD=%s\n", argv[1]);
    printf("CLAIM_REGISTRY_ID=%llu\n", (unsigned long long)actual);
    printf("RESULT=DISK_ARBITRATION_CLAIM_OK\n");
    fflush(stdout);

    const CFAbsoluteTime release_at = CFAbsoluteTimeGetCurrent() + (CFTimeInterval)hold_seconds;
    while (CFAbsoluteTimeGetCurrent() < release_at) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }

    DADiskUnclaim(disk);
    printf("RESULT=DISK_ARBITRATION_UNCLAIM_OK\n");
    fflush(stdout);
    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);
    return 0;
}
