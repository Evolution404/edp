#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

struct ProbeContext {
    DADiskRef disk;
    CFURLRef pathURL;
    char path[PATH_MAX];
    int done;
    int ok;
};

static void printDissenter(const char *prefix, DADissenterRef dissenter) {
    if (!dissenter) return;
    DAReturn status = DADissenterGetStatus(dissenter);
    CFStringRef text = DADissenterGetStatusString(dissenter);
    printf("%s_STATUS=0x%08x\n", prefix, (unsigned int)status);
    if (text) {
        char buffer[1024];
        if (CFStringGetCString(text, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            printf("%s_TEXT=%s\n", prefix, buffer);
        }
    }
}

static void mountCallback(DADiskRef disk, DADissenterRef dissenter, void *rawContext) {
    (void)disk;
    struct ProbeContext *context = rawContext;
    if (dissenter) {
        printDissenter("DA_REMOUNT_DISSENTER", dissenter);
        context->ok = 0;
    } else {
        puts("DA_REMOUNT_SUCCESS=1");
        context->ok = 1;
    }
    context->done = 1;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static void unmountCallback(DADiskRef disk, DADissenterRef dissenter, void *rawContext) {
    (void)disk;
    struct ProbeContext *context = rawContext;
    if (dissenter) {
        printDissenter("DA_UNMOUNT_DISSENTER", dissenter);
        context->ok = 0;
        context->done = 1;
        CFRunLoopStop(CFRunLoopGetCurrent());
        return;
    }

    puts("DA_UNMOUNT_SUCCESS=1");
    if (mkdir(context->path, 0755) != 0 && errno != EEXIST) {
        printf("MOUNTPOINT_RECREATE_ERRNO=%d\n", errno);
        context->ok = 0;
        context->done = 1;
        CFRunLoopStop(CFRunLoopGetCurrent());
        return;
    }

    static CFStringRef arguments[] = { CFSTR("nobrowse"), NULL };
    DADiskMountWithArguments(
        context->disk,
        context->pathURL,
        kDADiskMountOptionDefault,
        mountCallback,
        context,
        arguments
    );
}

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    if (strlen(argv[1]) >= PATH_MAX) return 65;

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return 66;
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    CFURLRef pathURL = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)argv[1],
        (CFIndex)strlen(argv[1]),
        true
    );
    if (!pathURL) {
        CFRelease(session);
        return 67;
    }

    DADiskRef disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, pathURL);
    if (!disk) {
        puts("DA_DISK_FROM_VOLUME_PATH=0");
        CFRelease(pathURL);
        CFRelease(session);
        return 2;
    }

    puts("DA_DISK_FROM_VOLUME_PATH=1");
    const char *bsdName = DADiskGetBSDName(disk);
    printf("DA_BSD_NAME=%s\n", bsdName ? bsdName : "<nil>");

    struct ProbeContext context = {0};
    context.disk = disk;
    context.pathURL = pathURL;
    strcpy(context.path, argv[1]);

    DADiskUnmount(disk, kDADiskUnmountOptionDefault, unmountCallback, &context);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 15.0, false);

    if (!context.done) {
        puts("DA_REMOUNT_CALLBACK_TIMEOUT=1");
        CFRelease(disk);
        CFRelease(pathURL);
        CFRelease(session);
        return 3;
    }

    CFRelease(disk);
    CFRelease(pathURL);
    CFRelease(session);
    return context.ok ? 0 : 4;
}
