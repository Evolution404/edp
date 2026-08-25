#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static const char *kFrameworkPath = "/System/Library/PrivateFrameworks/DiskImages2.framework/DiskImages2";

static void printError(NSError *error) {
    if (!error) return;
    fprintf(stderr, "DI_ERROR_DOMAIN=%s\n", error.domain.UTF8String ?: "(null)");
    fprintf(stderr, "DI_ERROR_CODE=%ld\n", (long)error.code);
    fprintf(stderr, "DI_ERROR=%s\n", error.description.UTF8String ?: "(null)");
}

static int attachCommon(NSURL *url, BOOL readOnly, BOOL autoMount) {
    Class commonAttachClass = NSClassFromString(@"DICommonAttach");
    if (!commonAttachClass) {
        fprintf(stderr, "DI_PRIVATE_CLASS_MISSING=DICommonAttach\n");
        return 10;
    }

    SEL attachSel = NSSelectorFromString(@"diskImageAttach:readOnly:autoMount:BSDName:error:");
    if (![commonAttachClass respondsToSelector:attachSel]) {
        fprintf(stderr, "DI_SELECTOR_MISSING=diskImageAttach:readOnly:autoMount:BSDName:error:\n");
        return 11;
    }
    printf("RESULT=DISKIMAGES2_COMMON_SELECTOR_FOUND\n");
    if (readOnly) {
        printf("RESULT=DISKIMAGES2_READONLY_SELECTOR_FOUND\n");
    }

    NSString *bsdName = nil;
    NSError *attachError = nil;
    typedef BOOL (*ReadOnlyAttachFn)(id, SEL, NSURL *, BOOL, BOOL, NSString **, NSError **);
    BOOL ok = ((ReadOnlyAttachFn)objc_msgSend)(
        commonAttachClass,
        attachSel,
        url,
        readOnly,
        autoMount,
        &bsdName,
        &attachError
    );

    if (!ok || attachError || bsdName.length == 0) {
        fprintf(stderr, "DI_COMMON_ATTACH_OK=%d\n", ok ? 1 : 0);
        printError(attachError);
        return 12;
    }

    printf("RESULT=DISKIMAGES2_COMMON_ATTACH_OK\n");
    if (readOnly) {
        printf("RESULT=DISKIMAGES2_READONLY_ATTACH_OK\n");
    }
    printf("DI_READ_ONLY=%s\n", readOnly ? "YES" : "NO");
    printf("DI_AUTO_MOUNT=%s\n", autoMount ? "YES" : "NO");
    printf("DI_BSD_NAME=%s\n", bsdName.UTF8String);
    printf("RESULT=DISKIMAGES2_PUBLISHED_BSD_DEVICE\n");
    fflush(stdout);
    return 0;
}

static int attachDefault(NSURL *url) {
    Class paramsClass = NSClassFromString(@"DIAttachParams");
    Class diskImagesClass = NSClassFromString(@"DiskImages2");
    if (!paramsClass || !diskImagesClass) {
        fprintf(stderr, "DI_PRIVATE_CLASSES_MISSING params=%p diskImages=%p\n", paramsClass, diskImagesClass);
        return 3;
    }
    printf("RESULT=DISKIMAGES2_PRIVATE_CLASSES_FOUND\n");

    SEL initSel = NSSelectorFromString(@"initWithURL:error:");
    if (![paramsClass instancesRespondToSelector:initSel]) {
        fprintf(stderr, "DI_SELECTOR_MISSING=initWithURL:error:\n");
        return 4;
    }

    NSError *initError = nil;
    typedef id (*InitFn)(id, SEL, NSURL *, NSError **);
    id params = ((InitFn)objc_msgSend)([paramsClass alloc], initSel, url, &initError);
    if (!params || initError) {
        printError(initError);
        return 5;
    }
    printf("RESULT=DI_ATTACH_PARAMS_CREATED\n");

    SEL attachSel = NSSelectorFromString(@"attachWithParams:handle:error:");
    if (![diskImagesClass respondsToSelector:attachSel]) {
        fprintf(stderr, "DI_SELECTOR_MISSING=attachWithParams:handle:error:\n");
        return 6;
    }

    NSError *attachError = nil;
    id deviceHandle = nil;
    typedef BOOL (*AttachFn)(id, SEL, id, id *, NSError **);
    BOOL ok = ((AttachFn)objc_msgSend)(diskImagesClass, attachSel, params, &deviceHandle, &attachError);
    if (!ok || attachError || !deviceHandle) {
        fprintf(stderr, "DI_ATTACH_OK=%d\n", ok ? 1 : 0);
        printError(attachError);
        return 7;
    }
    printf("RESULT=DISKIMAGES2_ATTACH_OK\n");

    SEL bsdSel = NSSelectorFromString(@"BSDName");
    if (![deviceHandle respondsToSelector:bsdSel]) {
        fprintf(stderr, "DI_SELECTOR_MISSING=BSDName\n");
        return 8;
    }
    typedef id (*ObjGetterFn)(id, SEL);
    NSString *bsdName = ((ObjGetterFn)objc_msgSend)(deviceHandle, bsdSel);
    if (bsdName.length == 0) {
        fprintf(stderr, "DI_BSD_NAME_EMPTY\n");
        return 9;
    }

    printf("DI_BSD_NAME=%s\n", bsdName.UTF8String);
    printf("RESULT=DISKIMAGES2_PUBLISHED_BSD_DEVICE\n");
    fflush(stdout);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL readOnly = NO;
        BOOL useCommonAttach = NO;
        BOOL autoMount = YES;
        const char *path = NULL;
        if (argc == 2) {
            path = argv[1];
        } else if (argc == 3 && strcmp(argv[1], "--readonly") == 0) {
            readOnly = YES;
            useCommonAttach = YES;
            autoMount = NO;
            path = argv[2];
        } else if (argc == 3 && strcmp(argv[1], "--writable-noautomount") == 0) {
            useCommonAttach = YES;
            autoMount = NO;
            path = argv[2];
        } else {
            fprintf(stderr,
                    "usage: %s [--readonly|--writable-noautomount] "
                    "<raw-backing-file>\n",
                    argv[0]);
            return 64;
        }

        void *framework = dlopen(kFrameworkPath, RTLD_NOW | RTLD_LOCAL);
        if (!framework) {
            fprintf(stderr, "DI_DLOPEN_ERROR=%s\n", dlerror());
            return 2;
        }
        printf("RESULT=DISKIMAGES2_FRAMEWORK_LOADED\n");

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        int rc = useCommonAttach
            ? attachCommon(url, readOnly, autoMount)
            : attachDefault(url);
        dlclose(framework);
        return rc;
    }
}
