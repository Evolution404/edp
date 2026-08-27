#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <stdio.h>
#include <string.h>

struct ProbeContext {
    int done;
    int ok;
};

static void mountCallback(DADiskRef disk, DADissenterRef dissenter, void *rawContext) {
    (void)disk;
    struct ProbeContext *context = rawContext;
    if (dissenter) {
        DAReturn status = DADissenterGetStatus(dissenter);
        CFStringRef text = DADissenterGetStatusString(dissenter);
        printf("DA_MOUNT_DISSENTER_STATUS=0x%08x\n", (unsigned int)status);
        if (text) {
            char buffer[1024];
            if (CFStringGetCString(text, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
                printf("DA_MOUNT_DISSENTER_TEXT=%s\n", buffer);
            }
        }
        context->ok = 0;
    } else {
        puts("DA_MOUNT_CALLBACK_SUCCESS=1");
        context->ok = 1;
    }
    context->done = 1;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

int main(int argc, char **argv) {
    if (argc != 2) return 64;

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return 65;
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    CFURLRef path = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)argv[1],
        (CFIndex)strlen(argv[1]),
        true
    );
    if (!path) {
        CFRelease(session);
        return 66;
    }

    DADiskRef disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, path);
    if (!disk) {
        puts("DA_DISK_FROM_VOLUME_PATH=0");
        CFRelease(path);
        CFRelease(session);
        return 2;
    }

    puts("DA_DISK_FROM_VOLUME_PATH=1");
    const char *bsdName = DADiskGetBSDName(disk);
    printf("DA_BSD_NAME=%s\n", bsdName ? bsdName : "<nil>");

    CFStringRef arguments[] = { CFSTR("nobrowse"), NULL };
    struct ProbeContext context = {0, 0};
    DADiskMountWithArguments(
        disk,
        path,
        kDADiskMountOptionDefault,
        mountCallback,
        &context,
        arguments
    );

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10.0, false);
    if (!context.done) {
        puts("DA_MOUNT_CALLBACK_TIMEOUT=1");
        CFRelease(disk);
        CFRelease(path);
        CFRelease(session);
        return 3;
    }

    CFRelease(disk);
    CFRelease(path);
    CFRelease(session);
    return context.ok ? 0 : 4;
}
