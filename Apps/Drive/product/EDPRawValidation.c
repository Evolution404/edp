#include "EDPRawValidation.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
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
        if (registry_has_property(current, "idVendor") && registry_has_property(current, "idProduct")) {
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
    for (int index = 0; index < 8; ++index) value |= ((uint64_t)bytes[index]) << (index * 8);
    return value;
}

static int lba4_has_only_id(const unsigned char sector[EDP_SECTOR_SIZE]) {
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
    if (payload_length < 1 || payload_length > 20) return 0;
    uint64_t only_id = 0;
    for (int index = payload_start; index < second; ++index) {
        unsigned char byte = sector[index];
        if (byte < '0' || byte > '9') return 0;
        uint64_t digit = (uint64_t)(byte - '0');
        if (only_id > (UINT64_MAX - digit) / 10u) return 0;
        only_id = only_id * 10u + digit;
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
            read_u64_le(plain + offset + 0x28) == 0) return 0;
    }
    return 1;
}

int edp_fd_has_edp_metadata(int fd) {
    unsigned char lba4[EDP_SECTOR_SIZE];
    unsigned char lba7[EDP_SECTOR_SIZE];
    if (pread_exact(fd, lba4, sizeof(lba4), (off_t)EDP_LBA4 * EDP_SECTOR_SIZE) != 0 ||
        pread_exact(fd, lba7, sizeof(lba7), (off_t)EDP_LBA7 * EDP_SECTOR_SIZE) != 0) return 0;
    return lba4_has_only_id(lba4) && lba7_has_edp_layout(lba7);
}

int edp_open_validated_raw_device_diagnostic(const char *raw_device, int *out_error_code) {
    if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_OK;
    if (!is_whole_raw_disk_path(raw_device) || !is_whole_usb_media(raw_device)) {
        if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_TARGET;
        errno = EPERM;
        return -1;
    }

    struct stat path_before;
    if (lstat(raw_device, &path_before) != 0 || !S_ISCHR(path_before.st_mode)) {
        if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_PATH_BEFORE;
        errno = EPERM;
        return -1;
    }

    int fd = open(raw_device, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (out_error_code) *out_error_code = errno != 0 ? errno : EIO;
        return -1;
    }

    struct stat status;
    if (fstat(fd, &status) != 0 || !S_ISCHR(status.st_mode)) {
        close(fd);
        if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_FSTAT;
        errno = EPERM;
        return -1;
    }

    struct stat path_after;
    if (lstat(raw_device, &path_after) != 0 || !S_ISCHR(path_after.st_mode)) {
        close(fd);
        if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_PATH_AFTER;
        errno = EPERM;
        return -1;
    }
    if (status.st_rdev != path_before.st_rdev || status.st_rdev != path_after.st_rdev) {
        close(fd);
        if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_RDEV_CHANGED;
        errno = EPERM;
        return -1;
    }
    if (!is_whole_usb_media(raw_device)) {
        close(fd);
        if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_MEDIA_CHANGED;
        errno = EPERM;
        return -1;
    }
    if (!edp_fd_has_edp_metadata(fd)) {
        close(fd);
        if (out_error_code) *out_error_code = EDP_RAW_VALIDATION_METADATA;
        errno = EPERM;
        return -1;
    }
    return fd;
}

int edp_open_validated_raw_device(const char *raw_device) {
    int diagnostic = EDP_RAW_VALIDATION_OK;
    int fd = edp_open_validated_raw_device_diagnostic(raw_device, &diagnostic);
    if (fd >= 0) return fd;
    if (diagnostic > 0 && diagnostic < 1000) errno = diagnostic;
    else errno = EPERM;
    return -1;
}
