#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <IOKit/IOKitLib.h>
#include <limits.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define EDP_SECTOR_SIZE 512
#define EDP_LBA4 4
#define EDP_LBA7 7

#ifndef EDP_ALLOW_SYNTHETIC_RAW_FIXTURE
#define EDP_ALLOW_SYNTHETIC_RAW_FIXTURE 0
#endif

static int parse_id(const char *text, unsigned long *value) {
    if (!text || !*text || !value) return -1;
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || !end || *end != '\0') return -1;
    *value = parsed;
    return 0;
}

static int allowed_executable(const char *path) {
    static const char *allowed[] = {
        "/Library/Application Support/EDP Drive/bin/edp-mfmount-local-readwrite",
    };
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); ++index) {
        if (strcmp(path, allowed[index]) == 0) return 1;
    }
    return 0;
}

static int is_raw_bridge_executable(const char *path) {
    static const char *allowed[] = {
        "/Library/Application Support/EDP Drive/bin/edp-mfmount-local-readwrite",
    };
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); ++index) {
        if (strcmp(path, allowed[index]) == 0) return 1;
    }
    return 0;
}

static int is_whole_raw_disk_path(const char *path) {
    static const char prefix[] = "/dev/rdisk";
    if (!path || strncmp(path, prefix, sizeof(prefix) - 1) != 0) return 0;
    const char *suffix = path + sizeof(prefix) - 1;
    if (*suffix == '\0') return 0;
    for (; *suffix != '\0'; ++suffix) {
        if (*suffix < '0' || *suffix > '9') return 0;
    }
    return 1;
}

static int raw_path_bsd_name(const char *path, char *out, size_t out_size) {
    if (!is_whole_raw_disk_path(path) || !out || out_size < 6) return -1;
    const char *source = path + strlen("/dev/r");
    size_t length = strlen(source);
    if (length + 1 > out_size) return -1;
    memcpy(out, source, length + 1);
    return 0;
}

static CFTypeRef copy_registry_property(io_registry_entry_t entry, const char *key) {
    CFStringRef cf_key = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!cf_key) return NULL;
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, cf_key, kCFAllocatorDefault, 0);
    CFRelease(cf_key);
    return value;
}

static int registry_string_equals(io_registry_entry_t entry, const char *key, const char *expected) {
    CFTypeRef value = copy_registry_property(entry, key);
    if (!value) return 0;
    int matches = 0;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        char buffer[128];
        if (CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            matches = strcmp(buffer, expected) == 0;
        }
    }
    CFRelease(value);
    return matches;
}

static int registry_bool_true(io_registry_entry_t entry, const char *key) {
    CFTypeRef value = copy_registry_property(entry, key);
    if (!value) return 0;
    int result = 0;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value) != 0;
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) result = number != 0;
    }
    CFRelease(value);
    return result;
}

static int registry_has_property(io_registry_entry_t entry, const char *key) {
    CFTypeRef value = copy_registry_property(entry, key);
    if (!value) return 0;
    CFRelease(value);
    return 1;
}

static int has_usb_ancestor(io_registry_entry_t service) {
    io_registry_entry_t current = service;
    int owns_current = 0;
    for (int depth = 0; depth < 32; ++depth) {
        if (registry_has_property(current, "idVendor") &&
            registry_has_property(current, "idProduct")) {
            if (owns_current) IOObjectRelease(current);
            return 1;
        }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        if (owns_current) IOObjectRelease(current);
        if (kr != KERN_SUCCESS || parent == IO_OBJECT_NULL) return 0;
        current = parent;
        owns_current = 1;
    }
    if (owns_current) IOObjectRelease(current);
    return 0;
}

static int is_whole_usb_media(const char *raw_path) {
    char bsd_name[64];
    if (raw_path_bsd_name(raw_path, bsd_name, sizeof(bsd_name)) != 0) return 0;

    CFMutableDictionaryRef matching = IOServiceMatching("IOMedia");
    if (!matching) return 0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) return 0;

    int found = 0;
    io_registry_entry_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (registry_string_equals(service, "BSD Name", bsd_name) &&
            registry_bool_true(service, "Whole") &&
            (has_usb_ancestor(service) || EDP_ALLOW_SYNTHETIC_RAW_FIXTURE)) {
            found = 1;
            IOObjectRelease(service);
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

static int pread_exact(int fd, void *buffer, size_t length, off_t offset) {
    unsigned char *cursor = (unsigned char *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t count = pread(fd, cursor + done, length - done, offset + (off_t)done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        done += (size_t)count;
    }
    return 0;
}

static uint32_t read_u32_le(const unsigned char *bytes) {
    return ((uint32_t)bytes[0]) |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static uint64_t read_u64_le(const unsigned char *bytes) {
    uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value |= ((uint64_t)bytes[index]) << (index * 8);
    }
    return value;
}

static int lba4_has_serial_marker(const unsigned char sector[EDP_SECTOR_SIZE]) {
    int first = -1;
    for (int index = 0; index <= EDP_SECTOR_SIZE - 3; ++index) {
        if (sector[index] == '$' && sector[index + 1] == '$' && sector[index + 2] == '$') {
            first = index;
            break;
        }
    }
    if (first < 0 || first > 64) return 0;
    int payload_start = first + 3;
    int second = -1;
    for (int index = payload_start; index <= EDP_SECTOR_SIZE - 3; ++index) {
        if (sector[index] == '$' && sector[index + 1] == '$' && sector[index + 2] == '$') {
            second = index;
            break;
        }
    }
    if (second < 0) return 0;
    int payload_length = second - payload_start;
    if (payload_length < 1 || payload_length > 96) return 0;
    for (int index = payload_start; index < second; ++index) {
        unsigned char byte = sector[index];
        if (byte == '$' || !(byte == 0x20 || (byte >= 0x21 && byte <= 0x7e))) return 0;
    }
    return 1;
}

static int lba7_has_edp_layout(const unsigned char cipher[EDP_SECTOR_SIZE]) {
    unsigned char plain[EDP_SECTOR_SIZE];
    memcpy(plain, cipher, sizeof(plain));
    uint16_t raw_word = (uint16_t)cipher[0] | ((uint16_t)cipher[1] << 8);
    uint32_t key = (uint32_t)(raw_word ^ 0x4445u);

    for (uint32_t index = 0; index < EDP_SECTOR_SIZE / 2; ++index) {
        size_t offset = (size_t)index * 2;
        uint16_t cipher_word = (uint16_t)plain[offset] | ((uint16_t)plain[offset + 1] << 8);
        uint16_t plain_word = cipher_word ^ (uint16_t)key;
        plain[offset] = (unsigned char)(plain_word & 0xffu);
        plain[offset + 1] = (unsigned char)((plain_word >> 8) & 0xffu);
        key = (key + 0x100u - index - 1u) & 0xffffu;
    }

    static const uint32_t expected_types[] = {1u, 2u, 4u};
    for (size_t index = 0; index < 3; ++index) {
        size_t offset = index * 0x40u;
        if (plain[offset] != 'E' || plain[offset + 1] != 'D' ||
            plain[offset + 2] != 'P' || plain[offset + 3] != 'F' ||
            read_u32_le(plain + offset + 0x0c) != expected_types[index] ||
            read_u64_le(plain + offset + 0x18) == 0 ||
            read_u64_le(plain + offset + 0x28) == 0) {
            return 0;
        }
    }
    return 1;
}

static int fd_has_edp_metadata(int fd) {
    unsigned char lba4[EDP_SECTOR_SIZE];
    unsigned char lba7[EDP_SECTOR_SIZE];
    if (pread_exact(fd, lba4, sizeof(lba4), (off_t)EDP_LBA4 * EDP_SECTOR_SIZE) != 0 ||
        pread_exact(fd, lba7, sizeof(lba7), (off_t)EDP_LBA7 * EDP_SECTOR_SIZE) != 0) {
        return 0;
    }
    return lba4_has_serial_marker(lba4) && lba7_has_edp_layout(lba7);
}

static int open_validated_edp_raw(const char *raw_device) {
    if (!is_whole_raw_disk_path(raw_device) || !is_whole_usb_media(raw_device)) {
        errno = EPERM;
        fprintf(stderr, "EDP_RAW_BROKER_TARGET_REFUSED\n");
        return -1;
    }

    struct stat path_before;
    if (lstat(raw_device, &path_before) != 0 || !S_ISCHR(path_before.st_mode)) {
        errno = EPERM;
        fprintf(stderr, "EDP_RAW_BROKER_PATH_REFUSED\n");
        return -1;
    }

    int fd = open(raw_device, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        fprintf(stderr, "EDP_RAW_BROKER_OPEN_FAILED:%d\n", errno);
        return -1;
    }
    struct stat status;
    struct stat path_after;
    if (fstat(fd, &status) != 0 || !S_ISCHR(status.st_mode) ||
        lstat(raw_device, &path_after) != 0 || !S_ISCHR(path_after.st_mode) ||
        status.st_rdev != path_before.st_rdev || status.st_rdev != path_after.st_rdev ||
        !is_whole_usb_media(raw_device)) {
        fprintf(stderr, "EDP_RAW_BROKER_TYPE_REFUSED\n");
        close(fd);
        errno = EPERM;
        return -1;
    }
    if (!fd_has_edp_metadata(fd)) {
        fprintf(stderr, "EDP_RAW_BROKER_METADATA_REFUSED\n");
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

static int install_raw_fd(int raw_fd) {
    if (raw_fd < 0) return -1;
    if (raw_fd != 3) {
        if (dup2(raw_fd, 3) < 0) {
            fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_DUP_FAILED:%d\n", errno);
            close(raw_fd);
            return -1;
        }
        close(raw_fd);
    } else if (fcntl(raw_fd, F_SETFD, 0) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_INHERIT_FAILED:%d\n", errno);
        close(raw_fd);
        return -1;
    }
    return 0;
}

static int prepare_inherited_raw_fd(void) {
    int descriptor_flags = fcntl(3, F_GETFD);
    struct stat status;
    if (descriptor_flags < 0 || fstat(3, &status) != 0 || !S_ISCHR(status.st_mode)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INHERITED_RAW_INVALID:%d\n", errno);
        return -1;
    }
    if (!fd_has_edp_metadata(3)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INHERITED_RAW_METADATA_REFUSED\n");
        errno = EPERM;
        return -1;
    }
    if ((descriptor_flags & FD_CLOEXEC) != 0 &&
        fcntl(3, F_SETFD, descriptor_flags & ~FD_CLOEXEC) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INHERITED_RAW_INHERIT_FAILED:%d\n", errno);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_REQUIRES_ROOT\n");
        return 77;
    }

    if (argc == 3 && strcmp(argv[1], "--probe-raw-device") == 0) {
        int raw_fd = open_validated_edp_raw(argv[2]);
        if (raw_fd < 0) return 77;
        close(raw_fd);
        printf("EDP_RAW_BROKER_PROBE_OK\n");
        return 0;
    }

    if (argc < 5) {
        fprintf(stderr, "usage: edp-console-exec <uid> <gid> [--raw-device /dev/rdiskN] -- <executable> [args...]\n");
        return 64;
    }

    const char *raw_device = NULL;
    int separator = 3;
    if (argc >= 7 && strcmp(argv[3], "--raw-device") == 0) {
        raw_device = argv[4];
        separator = 5;
    }
    if (separator >= argc - 1 || strcmp(argv[separator], "--") != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INVALID_ARGUMENTS\n");
        return 64;
    }
    int executable_index = separator + 1;

    unsigned long uid_value = 0;
    unsigned long gid_value = 0;
    if (parse_id(argv[1], &uid_value) != 0 || parse_id(argv[2], &gid_value) != 0 ||
        uid_value == 0 || uid_value > UINT_MAX || gid_value > UINT_MAX) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_INVALID_IDENTITY\n");
        return 64;
    }

    char resolved[PATH_MAX];
    if (!realpath(argv[executable_index], resolved) || !allowed_executable(resolved)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_REFUSED\n");
        return 77;
    }
    struct stat target_status;
    if (stat(resolved, &target_status) != 0 || !S_ISREG(target_status.st_mode) ||
        target_status.st_uid != 0 || (target_status.st_mode & 0022) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_TARGET_UNTRUSTED\n");
        return 77;
    }

    if (raw_device && !is_raw_bridge_executable(resolved)) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_RAW_DEVICE_REFUSED\n");
        return 77;
    }

    int raw_fd = -1;
    if (raw_device) {
        raw_fd = open_validated_edp_raw(raw_device);
        if (raw_fd < 0 || install_raw_fd(raw_fd) != 0) return 77;
    } else if (is_raw_bridge_executable(resolved) && prepare_inherited_raw_fd() != 0) {
        return 77;
    }

    uid_t uid = (uid_t)uid_value;
    gid_t gid = (gid_t)gid_value;
    struct passwd *account = getpwuid(uid);
    if (!account || account->pw_uid != uid || initgroups(account->pw_name, gid) != 0 ||
        setgid(gid) != 0 || setuid(uid) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_DROP_FAILED:%d\n", errno);
        return 77;
    }
    if (setenv("HOME", account->pw_dir, 1) != 0 ||
        setenv("USER", account->pw_name, 1) != 0 ||
        setenv("LOGNAME", account->pw_name, 1) != 0) {
        fprintf(stderr, "EDP_CONSOLE_EXEC_ENV_FAILED:%d\n", errno);
        return 77;
    }

    execv(resolved, &argv[executable_index]);
    fprintf(stderr, "EDP_CONSOLE_EXEC_EXEC_FAILED:%d\n", errno);
    return 71;
}
