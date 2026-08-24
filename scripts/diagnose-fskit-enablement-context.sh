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
#import <dlfcn.h>
#import <unistd.h>

static id callObjectNoArgs(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *safeString(id object) {
    if (!object || object == [NSNull null]) return @"unknown";
    return [object description];
}

int main(int argc, const char *argv[]) {
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
            printf("query_status=error\n");
            printf("error_domain=dlopen\n");
            printf("error_code=1\n");
            printf("error_description=%s\n", dlerror() ?: "unable to load FSKit");
            printf("target_found=unknown\n");
            printf("target_enabled=unknown\n");
            return 2;
        }

        Class FSClientClass = NSClassFromString(@"FSClient");
        if (!FSClientClass) {
            printf("query_status=error\n");
            printf("error_domain=runtime\n");
            printf("error_code=2\n");
            printf("error_description=FSClient class not found\n");
            printf("target_found=unknown\n");
            printf("target_enabled=unknown\n");
            dlclose(handle);
            return 2;
        }

        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        SEL fetchSel = NSSelectorFromString(@"fetchInstalledExtensionsWithCompletionHandler:");
        if (![FSClientClass respondsToSelector:sharedSel]) {
            printf("query_status=error\n");
            printf("error_domain=runtime\n");
            printf("error_code=3\n");
            printf("error_description=FSClient sharedInstance selector missing\n");
            printf("target_found=unknown\n");
            printf("target_enabled=unknown\n");
            dlclose(handle);
            return 2;
        }

        id client = callObjectNoArgs(FSClientClass, sharedSel);
        if (!client || ![client respondsToSelector:fetchSel]) {
            printf("query_status=error\n");
            printf("error_domain=runtime\n");
            printf("error_code=4\n");
            printf("error_description=fetchInstalledExtensions selector missing\n");
            printf("target_found=unknown\n");
            printf("target_enabled=unknown\n");
            dlclose(handle);
            return 2;
        }

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block BOOL callbackRan = NO;

        void (^completion)(NSArray *, NSError *) = ^(NSArray *identities, NSError *error) {
            callbackRan = YES;
            if (error) {
                NSString *desc = [[error localizedDescription] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                printf("query_status=error\n");
                printf("error_domain=%s\n", error.domain.UTF8String ?: "unknown");
                printf("error_code=%ld\n", (long)error.code);
                printf("error_description=%s\n", desc.UTF8String ?: "unknown");
                printf("target_found=unknown\n");
                printf("target_enabled=unknown\n");
                dispatch_semaphore_signal(semaphore);
                return;
            }

            NSArray *modules = identities ?: @[];
            printf("query_status=ok\n");
            printf("module_count=%lu\n", (unsigned long)modules.count);

            BOOL found = NO;
            for (id module in modules) {
                NSString *bundleID = nil;
                NSNumber *enabled = nil;
                NSURL *url = nil;
                @try {
                    bundleID = [module valueForKey:@"bundleIdentifier"];
                    enabled = [module valueForKey:@"enabled"];
                    url = [module valueForKey:@"url"];
                } @catch (NSException *exception) {
                    continue;
                }

                NSString *path = [url isKindOfClass:[NSURL class]] ? url.path : safeString(url);
                int enabledInt = [enabled respondsToSelector:@selector(boolValue)] && enabled.boolValue ? 1 : 0;
                const char *marker = [bundleID isEqualToString:targetBundle] ? "target" : "module";
                printf("%s_entry=%s|enabled=%d|url=%s\n",
                       marker,
                       bundleID.UTF8String ?: "unknown",
                       enabledInt,
                       path.UTF8String ?: "unknown");

                if ([bundleID isEqualToString:targetBundle]) {
                    found = YES;
                    printf("target_found=1\n");
                    printf("target_enabled=%d\n", enabledInt);
                    printf("target_url=%s\n", path.UTF8String ?: "unknown");
                }
            }

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
            printf("target_found=unknown\n");
            printf("target_enabled=unknown\n");
            fflush(stdout);
            dlclose(handle);
            return 124;
        }

        dlclose(handle);
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

USER_FOUND="$(extract_value "$USER_OUT" target_found)"
ROOT_FOUND="$(extract_value "$ROOT_OUT" target_found)"
ASUSER_FOUND="$(extract_value "$ASUSER_OUT" target_found)"
BACKUSER_FOUND="$(extract_value "$BACKUSER_OUT" target_found)"

USER_ENABLED="$(extract_value "$USER_OUT" target_enabled)"
ROOT_ENABLED="$(extract_value "$ROOT_OUT" target_enabled)"
ASUSER_ENABLED="$(extract_value "$ASUSER_OUT" target_enabled)"
BACKUSER_ENABLED="$(extract_value "$BACKUSER_OUT" target_enabled)"

section "SUMMARY"
log "user_direct_status=${USER_STATUS:-missing} user_direct_found=${USER_FOUND:-missing} user_direct_enabled=${USER_ENABLED:-missing}"
log "root_sudo_status=${ROOT_STATUS:-missing} root_sudo_found=${ROOT_FOUND:-missing} root_sudo_enabled=${ROOT_ENABLED:-missing}"
log "root_asuser_status=${ASUSER_STATUS:-missing} root_asuser_found=${ASUSER_FOUND:-missing} root_asuser_enabled=${ASUSER_ENABLED:-missing}"
log "sudo_back_user_status=${BACKUSER_STATUS:-missing} sudo_back_user_found=${BACKUSER_FOUND:-missing} sudo_back_user_enabled=${BACKUSER_ENABLED:-missing}"

if [[ "$USER_STATUS" != "ok" ]]; then
  log "RESULT=FSCLIENT_USER_QUERY_FAILED"
  log "Interpretation: FSClient itself could not return the installed-module list in the normal login-user context. Inspect the user query error before drawing conclusions about approval state."
elif [[ "$USER_FOUND" != "1" ]]; then
  log "RESULT=FSCLIENT_USER_CANNOT_SEE_MACFUSE_LOCAL"
  log "Interpretation: PlugInKit knows the extension, but FSKit's own FSClient does not expose macfuse-local to the login user. This is direct evidence of a discovery/state split."
elif [[ "$USER_ENABLED" == "0" ]]; then
  log "RESULT=FSCLIENT_USER_REPORTS_DISABLED"
  log "Interpretation: FSKit's own public API reports macfuse-local disabled for the login user. If PlugInKit shows '+', the two state views are inconsistent."
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "0" && "$ASUSER_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ENABLEMENT_DEPENDS_ON_USER_BOOTSTRAP"
  log "Interpretation: root sees the module disabled in the normal sudo context but enabled inside the login user's launchd bootstrap. This points to per-user/bootstrap state."
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "0" && "$BACKUSER_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ROOT_CONTEXT_REPORTS_DISABLED"
  log "Interpretation: FSKit reports the module enabled for the login UID but disabled for root. This matches the root-only MFMount preflight warning and supports a per-user enablement source."
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ENABLED_IN_USER_AND_ROOT"
  log "Interpretation: FSKit's public state reports macfuse-local enabled in both primary contexts. If a clean mount still returns requiresApproval, isEnabled is not the final LiveFiles authorization predicate."
else
  log "RESULT=FSCLIENT_CONTEXT_MATRIX_MIXED"
  log "Interpretation: inspect the four context outputs to distinguish effective UID, login-user bootstrap and per-user FSKit state."
fi

log "REPORT=$REPORT"
exit 0
