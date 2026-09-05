#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#import <unistd.h>

static const NSTimeInterval kDefaultTimeoutSeconds = 15.0;
static const NSTimeInterval kPollIntervalSeconds = 0.10;

typedef struct {
    uint16_t vendorID;
    uint16_t productID;
    uint64_t expectedRegistryEntryID;
    BOOL hasExpectedRegistryEntryID;
    NSTimeInterval timeoutSeconds;
    BOOL dryRun;
    BOOL selfTest;
} EDPOptions;

static void printUsage(void) {
    fprintf(stderr,
            "Usage: edp-usb-reenumerate --vid HEX --pid HEX [--registry-entry-id ID] [--timeout SECONDS] [--dry-run]\n"
            "       edp-usb-reenumerate --self-test\n"
            "\n"
            "Test-only helper using the public IOUSBHostDevice reset API.\n"
            "It does not write, format, partition, or mount storage.\n"
            "Actual reset requires root and refuses ambiguous VID/PID matches.\n");
}

static BOOL parseHex16(NSString *value, uint16_t *output) {
    if (value.length == 0 || value.length > 4) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    unsigned int parsed = 0;
    if (![scanner scanHexInt:&parsed] || !scanner.isAtEnd || parsed > UINT16_MAX) return NO;
    *output = (uint16_t)parsed;
    return YES;
}

static BOOL parseUInt64(NSString *value, uint64_t *output) {
    if (value.length == 0) return NO;
    int base = 10;
    const char *text = value.UTF8String;
    if (value.length > 2 && [value.lowercaseString hasPrefix:@"0x"]) base = 16;
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, base);
    if (errno != 0 || end == text || *end != '\0') return NO;
    *output = (uint64_t)parsed;
    return YES;
}

static BOOL parseTimeout(NSString *value, NSTimeInterval *output) {
    NSScanner *scanner = [NSScanner scannerWithString:value];
    double parsed = 0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || parsed < 1.0 || parsed > 60.0) return NO;
    *output = parsed;
    return YES;
}

static BOOL parseOptions(int argc, const char *argv[], EDPOptions *options, NSString **errorText) {
    EDPOptions result = {0};
    result.timeoutSeconds = kDefaultTimeoutSeconds;
    BOOL haveVID = NO;
    BOOL havePID = NO;

    for (int index = 1; index < argc; index++) {
        NSString *arg = [NSString stringWithUTF8String:argv[index]];
        if ([arg isEqualToString:@"--self-test"]) {
            result.selfTest = YES;
            continue;
        }
        if ([arg isEqualToString:@"--dry-run"]) {
            result.dryRun = YES;
            continue;
        }
        if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
            *errorText = @"help";
            return NO;
        }
        if (index + 1 >= argc) {
            *errorText = [NSString stringWithFormat:@"missing value for %@", arg];
            return NO;
        }
        NSString *value = [NSString stringWithUTF8String:argv[++index]];
        if ([arg isEqualToString:@"--vid"]) {
            if (!parseHex16(value, &result.vendorID)) {
                *errorText = @"invalid --vid (expected 1-4 hexadecimal digits)";
                return NO;
            }
            haveVID = YES;
        } else if ([arg isEqualToString:@"--pid"]) {
            if (!parseHex16(value, &result.productID)) {
                *errorText = @"invalid --pid (expected 1-4 hexadecimal digits)";
                return NO;
            }
            havePID = YES;
        } else if ([arg isEqualToString:@"--registry-entry-id"]) {
            if (!parseUInt64(value, &result.expectedRegistryEntryID)) {
                *errorText = @"invalid --registry-entry-id";
                return NO;
            }
            result.hasExpectedRegistryEntryID = YES;
        } else if ([arg isEqualToString:@"--timeout"]) {
            if (!parseTimeout(value, &result.timeoutSeconds)) {
                *errorText = @"invalid --timeout (expected 1-60 seconds)";
                return NO;
            }
        } else {
            *errorText = [NSString stringWithFormat:@"unknown argument: %@", arg];
            return NO;
        }
    }

    if (result.selfTest) {
        *options = result;
        return YES;
    }
    if (!haveVID || !havePID) {
        *errorText = @"--vid and --pid are required";
        return NO;
    }
    *options = result;
    return YES;
}

static NSArray<NSNumber *> *matchingRegistryEntryIDs(uint16_t vendorID, uint16_t productID) {
    CFMutableDictionaryRef matching = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(vendorID)
                                                                                  productID:@(productID)
                                                                                  bcdDevice:nil
                                                                                deviceClass:nil
                                                                             deviceSubclass:nil
                                                                             deviceProtocol:nil
                                                                                      speed:nil
                                                                             productIDArray:nil];
    if (matching == NULL) return @[];

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (status != KERN_SUCCESS) return @[];

    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint64_t registryEntryID = 0;
        if (IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS) {
            [ids addObject:@(registryEntryID)];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    [ids sortUsingComparator:^NSComparisonResult(NSNumber *left, NSNumber *right) {
        return [left compare:right];
    }];
    return ids;
}

static io_service_t copyMatchingService(uint16_t vendorID, uint16_t productID, uint64_t registryEntryID) {
    CFMutableDictionaryRef matching = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(vendorID)
                                                                                  productID:@(productID)
                                                                                  bcdDevice:nil
                                                                                deviceClass:nil
                                                                             deviceSubclass:nil
                                                                             deviceProtocol:nil
                                                                                      speed:nil
                                                                             productIDArray:nil];
    if (matching == NULL) return IO_OBJECT_NULL;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (status != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_service_t answer = IO_OBJECT_NULL;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint64_t currentID = 0;
        if (IORegistryEntryGetRegistryEntryID(service, &currentID) == KERN_SUCCESS && currentID == registryEntryID) {
            answer = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return answer;
}

static int runSelfTest(void) {
    uint16_t hexValue = 0;
    uint64_t integerValue = 0;
    NSTimeInterval timeout = 0;
    if (!parseHex16(@"21c4", &hexValue) || hexValue != 0x21c4) return 1;
    if (parseHex16(@"10000", &hexValue)) return 1;
    if (!parseUInt64(@"0x1234", &integerValue) || integerValue != 0x1234) return 1;
    if (!parseUInt64(@"4660", &integerValue) || integerValue != 4660) return 1;
    if (!parseTimeout(@"15", &timeout) || timeout != 15.0) return 1;
    if (parseTimeout(@"0", &timeout) || parseTimeout(@"61", &timeout)) return 1;
    printf("RESULT=EDP_USB_SOFTWARE_REENUMERATION_SELF_TEST_OK\n");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        EDPOptions options;
        NSString *parseError = nil;
        if (!parseOptions(argc, argv, &options, &parseError)) {
            if (![parseError isEqualToString:@"help"]) {
                fprintf(stderr, "ERROR=%s\n", parseError.UTF8String);
            }
            printUsage();
            return [parseError isEqualToString:@"help"] ? 0 : 2;
        }
        if (options.selfTest) return runSelfTest();

        NSArray<NSNumber *> *matches = matchingRegistryEntryIDs(options.vendorID, options.productID);
        if (options.hasExpectedRegistryEntryID) {
            NSIndexSet *indexes = [matches indexesOfObjectsPassingTest:^BOOL(NSNumber *value, NSUInteger idx, BOOL *stop) {
                (void)idx; (void)stop;
                return value.unsignedLongLongValue == options.expectedRegistryEntryID;
            }];
            matches = [matches objectsAtIndexes:indexes];
        }

        printf("TARGET_VID_PID=%04x:%04x\n", options.vendorID, options.productID);
        printf("MATCH_COUNT=%lu\n", (unsigned long)matches.count);
        if (matches.count != 1) {
            fprintf(stderr, "ERROR=expected exactly one matching IOUSBHostDevice; refusing ambiguous or absent target\n");
            return 3;
        }

        uint64_t oldRegistryEntryID = matches.firstObject.unsignedLongLongValue;
        printf("OLD_USB_REGISTRY_ENTRY_ID=%llu\n", oldRegistryEntryID);
        if (options.dryRun) {
            printf("RESULT=EDP_USB_SOFTWARE_REENUMERATION_TARGET_OK\n");
            return 0;
        }
        if (geteuid() != 0) {
            fprintf(stderr, "ERROR=actual USB reset requires root; rerun the compiled test helper with administrator privileges\n");
            return 4;
        }

        io_service_t service = copyMatchingService(options.vendorID, options.productID, oldRegistryEntryID);
        if (service == IO_OBJECT_NULL) {
            fprintf(stderr, "ERROR=target generation disappeared before reset\n");
            return 5;
        }

        NSError *openError = nil;
        IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service
                                                                     options:IOUSBHostObjectInitOptionsDeviceSeize
                                                                       queue:nil
                                                                       error:&openError
                                                             interestHandler:nil];
        IOObjectRelease(service);
        if (device == nil) {
            fprintf(stderr, "ERROR=IOUSBHostDevice open failed: %s\n", openError.localizedDescription.UTF8String);
            return 6;
        }

        NSError *resetError = nil;
        if (![device resetWithError:&resetError]) {
            [device destroy];
            fprintf(stderr, "ERROR=IOUSBHostDevice reset failed: %s\n", resetError.localizedDescription.UTF8String);
            return 7;
        }
        printf("RESET_REQUEST=OK\n");

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:options.timeoutSeconds];
        BOOL oldGenerationGone = NO;
        uint64_t newRegistryEntryID = 0;
        while ([deadline timeIntervalSinceNow] > 0) {
            NSArray<NSNumber *> *current = matchingRegistryEntryIDs(options.vendorID, options.productID);
            oldGenerationGone = ![current containsObject:@(oldRegistryEntryID)];
            NSArray<NSNumber *> *replacement = [current filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(NSNumber *value, NSDictionary<NSString *, id> *bindings) {
                    (void)bindings;
                    return value.unsignedLongLongValue != oldRegistryEntryID;
                }]];
            if (oldGenerationGone && replacement.count == 1) {
                newRegistryEntryID = replacement.firstObject.unsignedLongLongValue;
                break;
            }
            [NSThread sleepForTimeInterval:kPollIntervalSeconds];
        }

        printf("OLD_GENERATION_GONE=%s\n", oldGenerationGone ? "true" : "false");
        if (!oldGenerationGone || newRegistryEntryID == 0) {
            fprintf(stderr, "ERROR=USB device did not re-enumerate as one new generation before timeout\n");
            return 8;
        }
        printf("NEW_USB_REGISTRY_ENTRY_ID=%llu\n", newRegistryEntryID);
        printf("RESULT=EDP_USB_SOFTWARE_REENUMERATION_OK\n");
        return 0;
    }
}
