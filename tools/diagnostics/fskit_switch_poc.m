#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <bsm/audit.h>

static void dump_protocol(NSString *name) {
    Protocol *p = objc_getProtocol(name.UTF8String);
    if (!p) {
        printf("PROTO %s: MISSING\n", name.UTF8String);
        return;
    }
    printf("PROTO %s: FOUND\n", name.UTF8String);
    for (int required = 0; required <= 1; required++) {
        unsigned int count = 0;
        struct objc_method_description *methods = protocol_copyMethodDescriptionList(
            p, required, YES, &count);
        printf("  %s instance count=%u\n", required ? "required" : "optional", count);
        for (unsigned int i = 0; i < count; i++) {
            printf("    %s types=%s\n",
                   sel_getName(methods[i].name),
                   methods[i].types ? methods[i].types : "<null>");
        }
        free(methods);
    }
}

static void dump_class_methods(Class cls) {
    if (!cls) return;
    Class meta = object_getClass(cls);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(meta, &count);
    printf("CLASS %s class-methods=%u\n", class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        printf("  + %s types=%s\n",
               sel_getName(method_getName(methods[i])),
               method_getTypeEncoding(methods[i]));
    }
    free(methods);
}

static audit_token_t self_audit_token(void) {
    audit_token_t token = {0};
#ifdef TASK_AUDIT_TOKEN
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN,
                                 (task_info_t)&token, &count);
    printf("SELF_AUDIT_TOKEN task_info kr=%d count=%u\n", kr, count);
#else
    printf("SELF_AUDIT_TOKEN TASK_AUDIT_TOKEN unavailable at compile time\n");
#endif
    return token;
}

static int invoke_helper(Class helper,
                         NSString *shortName,
                         NSString *deviceName,
                         NSString *mountPoint,
                         NSString *volumeName,
                         NSString *mountOptions) {
    NSArray<NSString *> *selectors = @[
        @"DAMountFSKitVolume:deviceName:mountPoint:volumeName:auditToken:mountOptions:",
        @"DAMountFSKitVolume:deviceName:mountPoint:volumeName:mountOptions:"
    ];

    for (NSString *selectorName in selectors) {
        SEL sel = NSSelectorFromString(selectorName);
        NSMethodSignature *sig = [helper methodSignatureForSelector:sel];
        if (!sig) continue;

        printf("HELPER_SELECTED selector=%s nargs=%lu return=%s\n",
               selectorName.UTF8String,
               (unsigned long)sig.numberOfArguments,
               sig.methodReturnType);
        for (NSUInteger i = 0; i < sig.numberOfArguments; i++) {
            printf("  arg[%lu]=%s\n", (unsigned long)i,
                   [sig getArgumentTypeAtIndex:i]);
        }

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = helper;
        inv.selector = sel;

        id a0 = shortName;
        id a1 = deviceName;
        id a2 = mountPoint;
        id a3 = volumeName;
        [inv setArgument:&a0 atIndex:2];
        [inv setArgument:&a1 atIndex:3];
        [inv setArgument:&a2 atIndex:4];
        [inv setArgument:&a3 atIndex:5];

        if ([selectorName containsString:@"auditToken:"]) {
            audit_token_t token = self_audit_token();
            const char *type = [sig getArgumentTypeAtIndex:6];
            NSUInteger size = 0, align = 0;
            NSGetSizeAndAlignment(type, &size, &align);
            printf("  auditToken encoded-size=%lu local-size=%lu\n",
                   (unsigned long)size, (unsigned long)sizeof(token));
            if (size == sizeof(token)) {
                [inv setArgument:&token atIndex:6];
            } else {
                void *zero = calloc(1, MAX(size, (NSUInteger)1));
                [inv setArgument:zero atIndex:6];
                free(zero);
            }
            id opts = mountOptions;
            [inv setArgument:&opts atIndex:7];
        } else {
            id opts = mountOptions;
            [inv setArgument:&opts atIndex:6];
        }

        @try {
            [inv invoke];
        } @catch (NSException *e) {
            printf("HELPER_EXCEPTION name=%s reason=%s\n",
                   e.name.UTF8String, e.reason.UTF8String);
            return 254;
        }

        int rc = -9999;
        if (sig.methodReturnLength == sizeof(int)) {
            [inv getReturnValue:&rc];
        } else {
            printf("HELPER_UNEXPECTED_RETURN_LENGTH=%lu\n",
                   (unsigned long)sig.methodReturnLength);
        }
        printf("HELPER_RC=%d\n", rc);
        return rc;
    }

    printf("HELPER_SELECTOR_NOT_FOUND\n");
    return 253;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <bsd-name-without-/dev/> <mount-point>\n", argv[0]);
            return 2;
        }

        printf("=== LOAD FRAMEWORKS ===\n");
        const char *paths[] = {
            "/System/Library/Frameworks/FSKit.framework/FSKit",
            "/System/Library/PrivateFrameworks/FSKit.framework/FSKit",
            "/System/Library/PrivateFrameworks/LiveFS.framework/LiveFS"
        };
        for (unsigned i = 0; i < sizeof(paths)/sizeof(paths[0]); i++) {
            void *h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
            printf("dlopen %s => %p%s%s\n", paths[i], h,
                   h ? "" : " error=", h ? "" : dlerror());
        }

        printf("\n=== RUNTIME CONTRACT ===\n");
        dump_protocol(@"LiveFSMounterUnentitled");
        dump_protocol(@"LiveFSMounter");

        Class fsClient = NSClassFromString(@"FSClient");
        Class helper = NSClassFromString(@"FSKitDiskArbHelper");
        printf("FSClient=%p FSKitDiskArbHelper=%p\n", fsClient, helper);
        dump_class_methods(helper);

        printf("\n=== FSCLIENT SWITCH HANDSHAKE ===\n");
        if (fsClient) {
            id client = [[fsClient alloc] init];
            printf("FSCLIENT_INIT=%s\n", client ? "SUCCESS" : "FAIL");
            if (client && [fsClient respondsToSelector:NSSelectorFromString(@"installedExtensionsWithError:")]) {
                NSError *error = nil;
                typedef id (*InstalledFn)(id, SEL, NSError **);
                InstalledFn fn = (InstalledFn)objc_msgSend;
                id extensions = fn(fsClient,
                    NSSelectorFromString(@"installedExtensionsWithError:"), &error);
                printf("FSCLIENT_INSTALLED_EXTENSIONS count=%lu error=%s\n",
                       (unsigned long)[extensions count],
                       error ? error.description.UTF8String : "<nil>");
                for (id ext in extensions) {
                    NSString *desc = [ext description];
                    if ([desc localizedCaseInsensitiveContainsString:@"msdos"] ||
                        [desc localizedCaseInsensitiveContainsString:@"fat"]) {
                        printf("  EXT %s\n", desc.UTF8String);
                    }
                }
            }
        } else {
            printf("FSCLIENT_INIT=CLASS_MISSING\n");
        }

        printf("\n=== DIRECT FSKIT DISKARB HELPER MOUNT ===\n");
        if (!helper) {
            printf("HELPER_CLASS_MISSING\n");
            return 252;
        }

        NSString *bsd = [NSString stringWithUTF8String:argv[1]];
        NSString *mp = [NSString stringWithUTF8String:argv[2]];
        int rc = invoke_helper(helper, @"msdos", bsd, mp, @"EDPFAT", @"");
        printf("POC_FINAL_RC=%d\n", rc);
        return rc == 0 ? 0 : 1;
    }
}
