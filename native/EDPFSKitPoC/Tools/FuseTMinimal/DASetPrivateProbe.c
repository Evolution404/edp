#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <stdio.h>
#include <string.h>

/* Removed from the macOS 26.5 SDK. Historical public value. Diagnostic only. */
static const DADiskOptions kEDPLegacyDADiskOptionPrivate = 0x00000100u;

int main(int argc, char **argv) {
    if (argc != 2) return 64;

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return 65;

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

    DADiskOptions before = DADiskGetOptions(disk);
    printf("DA_PRIVATE_BEFORE=%d OPTIONS=0x%08x\n",
           (before & kEDPLegacyDADiskOptionPrivate) != 0,
           (unsigned int)before);

    DAReturn status = DADiskSetOptions(disk, kEDPLegacyDADiskOptionPrivate, true);
    printf("DA_SET_PRIVATE_STATUS=0x%08x\n", (unsigned int)status);

    DADiskOptions after = DADiskGetOptions(disk);
    printf("DA_PRIVATE_AFTER=%d OPTIONS=0x%08x\n",
           (after & kEDPLegacyDADiskOptionPrivate) != 0,
           (unsigned int)after);

    CFRelease(disk);
    CFRelease(path);
    CFRelease(session);

    if (status != kDAReturnSuccess) return 3;
    return (after & kEDPLegacyDADiskOptionPrivate) ? 0 : 4;
}
