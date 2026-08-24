#!/bin/bash
set -u
set -o pipefail

TARGET_BUNDLE="io.macfuse.app.fsmodule.macfuse-local"
BASE="${TMPDIR:-/tmp}/edp-fskit-enablement-context"
REPORT="$BASE/report.txt"
OBJC_SRC="$BASE/fskit-state.m"
HELPER="$BASE/fskit-state"
BUILD_LOG="$BASE/helper-build.log"
USER_OUT="$BASE/user-direct.txt"
ROOT_OUT="$BASE/root-sudo.txt"
ASUSER_OUT="$BASE/root-asuser.txt"
BACKUSER_OUT="$BASE/sudo-back-user.txt"
PLUGIN_USER_OUT="$BASE/pluginkit-user.txt"
PLUGIN_ROOT_OUT="$BASE/pluginkit-root.txt"

UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
USER_NOW="$(id -un)"
OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"

mkdir -p "$BASE"
: > "$REPORT"
: > "$BUILD_LOG"

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$REPORT"
}

section() {
  log ""
  log "=== $* ==="
}

cleanup() {
  /bin/rm -f "$HELPER" "$OBJC_SRC" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

extract_value() {
  local file="$1"
  local key="$2"
  /usr/bin/sed -n "s/^${key}=//p" "$file" 2>/dev/null | /usr/bin/tail -n 1
}

show_file() {
  local file="$1"
  if [[ -s "$file" ]]; then
    /bin/cat "$file" | /usr/bin/tee -a "$REPORT"
  else
    log "(no output)"
  fi
}

run_context() {
  local label="$1"
  local outfile="$2"
  shift 2
  : > "$outfile"
  "$@" > "$outfile" 2>&1
  local rc=$?
  section "$label"
  log "command_rc=$rc"
  show_file "$outfile"
  return 0
}

section "System"
/usr/bin/sw_vers 2>&1 | /usr/bin/tee -a "$REPORT"
log "shell_uid=$UID_NOW shell_gid=$GID_NOW shell_user=$USER_NOW"
log "target_bundle=$TARGET_BUNDLE"

section "PlugInKit state as login user"
/usr/bin/pluginkit -mAvvv -i "$TARGET_BUNDLE" > "$PLUGIN_USER_OUT" 2>&1 || true
show_file "$PLUGIN_USER_OUT"

section "Installed macFUSE FSKit extension"
LOCAL_APPEX="$(/usr/bin/sed -n 's/^[[:space:]]*Path = //p' "$PLUGIN_USER_OUT" | /usr/bin/head -n 1)"
if [[ -n "$LOCAL_APPEX" && -d "$LOCAL_APPEX" ]]; then
  log "appex_present=1"
  log "appex_path=$LOCAL_APPEX"
  /usr/bin/codesign -dv --verbose=2 "$LOCAL_APPEX" 2>&1 | /usr/bin/grep -E 'Identifier=|TeamIdentifier=|Authority=' | /usr/bin/tee -a "$REPORT" || true
else
  log "appex_present=0"
  log "appex_path=${LOCAL_APPEX:-not-resolved}"
fi

section "Prepare FSClient helper"
/bin/cat > "$OBJC_SRC" <<'OBJC'
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>

static id callObjectNoArgs(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL callBoolNoArgs(id object, SEL selector) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *oneLine(id object) {
    if (!object || object == [NSNull null]) return @"unknown";
    NSString *s = [object description] ?: @"unknown";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return s;
}

static id objectForFirstSelector(id object, NSArray<NSString *> *names, NSString **usedName) {
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if ([object respondsToSelector:sel]) {
            if (usedName) *usedName = name;
            return callObjectNoArgs(object, sel);
        }
    }
    if (usedName) *usedName = nil;
    return nil;
}

static NSNumber *boolForFirstSelector(id object, NSArray<NSString *> *names, NSString **usedName) {
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if ([object respondsToSelector:sel]) {
            if (usedName) *usedName = name;
            return @(callBoolNoArgs(object, sel));
        }
    }
    if (usedName) *usedName = nil;
    return nil;
}

int main(void) {
    @autoreleasepool {
        NSString *targetBundle = @"io.macfuse.app.fsmodule.macfuse-local";
        printf("process_uid=%u\n", getuid());
        printf("process_euid=%u\n", geteuid());
        printf("process_gid=%u\n", getgid());
        printf("process_egid=%u\n", getegid());
        printf("process_user=%s\n", NSUserName().UTF8String ?: "unknown");
        printf("home=%s\n", NSHomeDirectory().UTF8String ?: "unknown");

        void *handle = dlopen("/System/Library/Frameworks/FSKit.framework/FSKit", RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            printf("query_status=error\nerror_domain=dlopen\nerror_code=1\n");
            printf("error_description=%s\n", dlerror() ?: "unable to load FSKit");
            printf("target_found=unknown\ntarget_enabled=unknown\n");
            return 2;
        }

        Class FSClientClass = NSClassFromString(@"FSClient");
        if (!FSClientClass) {
            printf("query_status=error\nerror_domain=runtime\nerror_code=2\n");
            printf("error_description=FSClient class not found\n");
            printf("target_found=unknown\ntarget_enabled=unknown\n");
            return 2;
        }

        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        SEL fetchSel = NSSelectorFromString(@"fetchInstalledExtensionsWithCompletionHandler:");
        if (![FSClientClass respondsToSelector:sharedSel]) {
            printf("query_status=error\nerror_domain=runtime\nerror_code=3\n");
            printf("error_description=FSClient sharedInstance selector missing\n");
            printf("target_found=unknown\ntarget_enabled=unknown\n");
            return 2;
        }

        id client = callObjectNoArgs(FSClientClass, sharedSel);
        if (!client || ![client respondsToSelector:fetchSel]) {
            printf("query_status=error\nerror_domain=runtime\nerror_code=4\n");
            printf("error_description=fetchInstalledExtensions selector missing\n");
            printf("target_found=unknown\ntarget_enabled=unknown\n");
            return 2;
        }

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block BOOL callbackRan = NO;

        void (^completion)(NSArray *, NSError *) = ^(NSArray *identities, NSError *error) {
            callbackRan = YES;
            if (error) {
                printf("query_status=error\n");
                printf("error_domain=%s\n", error.domain.UTF8String ?: "unknown");
                printf("error_code=%ld\n", (long)error.code);
                printf("error_description=%s\n", oneLine(error.localizedDescription).UTF8String ?: "unknown");
                printf("target_found=unknown\ntarget_enabled=unknown\n");
                dispatch_semaphore_signal(semaphore);
                return;
            }

            NSArray *modules = identities ?: @[];
            printf("query_status=ok\n");
            printf("module_count=%lu\n", (unsigned long)modules.count);

            BOOL found = NO;
            NSUInteger decodedIDs = 0;
            NSUInteger decodeFailures = 0;
            NSUInteger index = 0;

            for (id module in modules) {
                index++;
                NSString *className = NSStringFromClass([module class]) ?: @"unknown";
                NSString *bundleSelName = nil;
                NSString *enabledSelName = nil;
                NSString *urlSelName = nil;

                id bundleObject = objectForFirstSelector(module, @[@"bundleIdentifier", @"bundleID", @"identifier"], &bundleSelName);
                NSNumber *enabledObject = boolForFirstSelector(module, @[@"isEnabled", @"enabled"], &enabledSelName);
                id urlObject = objectForFirstSelector(module, @[@"url", @"URL"], &urlSelName);

                NSString *bundleID = [bundleObject isKindOfClass:[NSString class]] ? bundleObject : nil;
                NSString *path = nil;
                if ([urlObject isKindOfClass:[NSURL class]]) {
                    path = [(NSURL *)urlObject path];
                } else if (urlObject) {
                    path = oneLine(urlObject);
                }

                printf("module_%lu_class=%s\n", (unsigned long)index, className.UTF8String ?: "unknown");
                printf("module_%lu_description=%s\n", (unsigned long)index, oneLine(module).UTF8String ?: "unknown");
                printf("module_%lu_bundle_selector=%s\n", (unsigned long)index, bundleSelName.UTF8String ?: "none");
                printf("module_%lu_enabled_selector=%s\n", (unsigned long)index, enabledSelName.UTF8String ?: "none");
                printf("module_%lu_url_selector=%s\n", (unsigned long)index, urlSelName.UTF8String ?: "none");
                printf("module_%lu_bundle=%s\n", (unsigned long)index, bundleID.UTF8String ?: "unknown");
                printf("module_%lu_enabled=%s\n", (unsigned long)index, enabledObject ? (enabledObject.boolValue ? "1" : "0") : "unknown");
                printf("module_%lu_url=%s\n", (unsigned long)index, path.UTF8String ?: "unknown");

                if (bundleID) decodedIDs++; else decodeFailures++;
                if (bundleID && [bundleID isEqualToString:targetBundle]) {
                    found = YES;
                    printf("target_found=1\n");
                    printf("target_enabled=%s\n", enabledObject ? (enabledObject.boolValue ? "1" : "0") : "unknown");
                    printf("target_url=%s\n", path.UTF8String ?: "unknown");
                }
            }

            printf("decoded_id_count=%lu\n", (unsigned long)decodedIDs);
            printf("decode_failure_count=%lu\n", (unsigned long)decodeFailures);
            if (!found) {
                printf("target_found=0\n");
                printf("target_enabled=unknown\n");
                printf("target_url=unknown\n");
            }
            fflush(stdout);
            dispatch_semaphore_signal(semaphore);
        };

        typedef void (*FetchFn)(id, SEL, void (^)(NSArray *, NSError *));
        ((FetchFn)objc_msgSend)(client, fetchSel, completion);

        long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC));
        if (waitResult != 0 || !callbackRan) {
            printf("query_status=timeout\n");
            printf("target_found=unknown\ntarget_enabled=unknown\n");
            fflush(stdout);
            return 124;
        }
        return 0;
    }
}
OBJC

if ! /usr/bin/xcrun --sdk macosx clang -fobjc-arc -fblocks -O0 "$OBJC_SRC" -framework Foundation -o "$HELPER" > "$BUILD_LOG" 2>&1; then
  log "helper_build=failed"
  section "Helper compiler diagnostics"
  show_file "$BUILD_LOG"
  log "RESULT=FSCLIENT_HELPER_BUILD_FAILED"
  log "REPORT=$REPORT"
  exit 2
fi
/bin/chmod 755 "$HELPER"
log "helper_build=ok"

run_context "A. FSClient as current login user" "$USER_OUT" "$HELPER"

section "Authorize sudo for read-only context comparison"
if ! /usr/bin/sudo -v; then
  log "sudo_authorization=failed"
  log "RESULT=FSCLIENT_ROOT_CONTEXT_NOT_TESTED"
  log "REPORT=$REPORT"
  exit 3
fi
log "sudo_authorization=ok"

section "PlugInKit state as root"
/usr/bin/sudo /usr/bin/pluginkit -mAvvv -i "$TARGET_BUNDLE" > "$PLUGIN_ROOT_OUT" 2>&1 || true
show_file "$PLUGIN_ROOT_OUT"

run_context "B. FSClient as sudo root" "$ROOT_OUT" /usr/bin/sudo "$HELPER"
run_context "C. FSClient as root inside login-user bootstrap" "$ASUSER_OUT" /usr/bin/sudo /bin/launchctl asuser "$UID_NOW" "$HELPER"
run_context "D. FSClient after sudo drops back to login UID" "$BACKUSER_OUT" /usr/bin/sudo -u "$USER_NOW" "$HELPER"

USER_STATUS="$(extract_value "$USER_OUT" query_status)"
ROOT_STATUS="$(extract_value "$ROOT_OUT" query_status)"
ASUSER_STATUS="$(extract_value "$ASUSER_OUT" query_status)"
BACKUSER_STATUS="$(extract_value "$BACKUSER_OUT" query_status)"
USER_COUNT="$(extract_value "$USER_OUT" module_count)"
ROOT_COUNT="$(extract_value "$ROOT_OUT" module_count)"
ASUSER_COUNT="$(extract_value "$ASUSER_OUT" module_count)"
BACKUSER_COUNT="$(extract_value "$BACKUSER_OUT" module_count)"
USER_DECODED="$(extract_value "$USER_OUT" decoded_id_count)"
ROOT_DECODED="$(extract_value "$ROOT_OUT" decoded_id_count)"
ASUSER_DECODED="$(extract_value "$ASUSER_OUT" decoded_id_count)"
BACKUSER_DECODED="$(extract_value "$BACKUSER_OUT" decoded_id_count)"
USER_FAILED="$(extract_value "$USER_OUT" decode_failure_count)"
ROOT_FAILED="$(extract_value "$ROOT_OUT" decode_failure_count)"
ASUSER_FAILED="$(extract_value "$ASUSER_OUT" decode_failure_count)"
BACKUSER_FAILED="$(extract_value "$BACKUSER_OUT" decode_failure_count)"
USER_FOUND="$(extract_value "$USER_OUT" target_found)"
ROOT_FOUND="$(extract_value "$ROOT_OUT" target_found)"
ASUSER_FOUND="$(extract_value "$ASUSER_OUT" target_found)"
BACKUSER_FOUND="$(extract_value "$BACKUSER_OUT" target_found)"
USER_ENABLED="$(extract_value "$USER_OUT" target_enabled)"
ROOT_ENABLED="$(extract_value "$ROOT_OUT" target_enabled)"
ASUSER_ENABLED="$(extract_value "$ASUSER_OUT" target_enabled)"
BACKUSER_ENABLED="$(extract_value "$BACKUSER_OUT" target_enabled)"

section "SUMMARY"
log "user_direct_status=${USER_STATUS:-missing} module_count=${USER_COUNT:-missing} decoded=${USER_DECODED:-missing} decode_failed=${USER_FAILED:-missing} found=${USER_FOUND:-missing} enabled=${USER_ENABLED:-missing}"
log "root_sudo_status=${ROOT_STATUS:-missing} module_count=${ROOT_COUNT:-missing} decoded=${ROOT_DECODED:-missing} decode_failed=${ROOT_FAILED:-missing} found=${ROOT_FOUND:-missing} enabled=${ROOT_ENABLED:-missing}"
log "root_asuser_status=${ASUSER_STATUS:-missing} module_count=${ASUSER_COUNT:-missing} decoded=${ASUSER_DECODED:-missing} decode_failed=${ASUSER_FAILED:-missing} found=${ASUSER_FOUND:-missing} enabled=${ASUSER_ENABLED:-missing}"
log "sudo_back_user_status=${BACKUSER_STATUS:-missing} module_count=${BACKUSER_COUNT:-missing} decoded=${BACKUSER_DECODED:-missing} decode_failed=${BACKUSER_FAILED:-missing} found=${BACKUSER_FOUND:-missing} enabled=${BACKUSER_ENABLED:-missing}"

if [[ "$USER_STATUS" != "ok" ]]; then
  log "RESULT=FSCLIENT_USER_QUERY_FAILED"
elif [[ "${USER_COUNT:-0}" != "0" && "${USER_DECODED:-0}" == "0" ]]; then
  log "RESULT=FSCLIENT_IDENTITY_DECODE_INCONCLUSIVE"
  log "Interpretation: FSClient returned module objects, but this diagnostic could not decode their bundle identifiers."
elif [[ "${USER_FAILED:-0}" != "0" ]]; then
  log "RESULT=FSCLIENT_IDENTITY_DECODE_PARTIAL"
  log "Interpretation: one or more FSClient identities could not be decoded."
elif [[ "$USER_FOUND" != "1" && "$OS_MAJOR" -lt 26 ]]; then
  log "RESULT=FSCLIENT_THIRD_PARTY_ENUM_UNSUPPORTED_ON_MACOS15"
  log "Interpretation: on macOS 15.x, absence of macfuse-local from FSClient is not evidence of a registration or approval split. macFUSE release notes state that macOS 26 added third-party FS extension information to FSClient. Use PlugInKit, the per-user enabledModules state and actual mount behavior instead."
elif [[ "$USER_FOUND" != "1" ]]; then
  log "RESULT=FSCLIENT_USER_CANNOT_SEE_MACFUSE_LOCAL"
  log "Interpretation: on this OS generation FSClient is expected to expose third-party extensions, so target absence is relevant."
elif [[ "$USER_ENABLED" == "0" ]]; then
  log "RESULT=FSCLIENT_USER_REPORTS_DISABLED"
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "0" && "$ASUSER_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ENABLEMENT_DEPENDS_ON_USER_BOOTSTRAP"
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "0" && "$BACKUSER_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ROOT_CONTEXT_REPORTS_DISABLED"
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ENABLED_IN_USER_AND_ROOT"
else
  log "RESULT=FSCLIENT_CONTEXT_MATRIX_MIXED"
fi

log "REPORT=$REPORT"
exit 0
