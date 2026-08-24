#!/bin/bash
set -u
set -o pipefail

TARGET_BUNDLE="io.macfuse.app.fsmodule.macfuse-local"
BASE="${TMPDIR:-/tmp}/edp-fskit-enablement-context"
REPORT="$BASE/report.txt"
SWIFT_SRC="$BASE/fskit-state.swift"
HELPER="$BASE/fskit-state"
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

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$REPORT"
}

section() {
  log ""
  log "=== $* ==="
}

cleanup() {
  /bin/rm -f "$HELPER" "$SWIFT_SRC" >/dev/null 2>&1 || true
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

section "Installed macFUSE FSKit extension"
LOCAL_APPEX="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/PlugIns/io.macfuse.app.fsmodule.macfuse-local.appex"
if [[ -d "$LOCAL_APPEX" ]]; then
  log "appex_present=1"
  log "appex_path=$LOCAL_APPEX"
  /usr/bin/codesign -dv --verbose=2 "$LOCAL_APPEX" 2>&1 | /usr/bin/grep -E 'Identifier=|TeamIdentifier=|Authority=' | /usr/bin/tee -a "$REPORT" || true
else
  log "appex_present=0"
fi

section "PlugInKit state as login user"
/usr/bin/pluginkit -mAvvv -i "$TARGET_BUNDLE" > "$PLUGIN_USER_OUT" 2>&1 || true
show_file "$PLUGIN_USER_OUT"

section "Prepare FSClient helper"
cat > "$SWIFT_SRC" <<'SWIFT'
import Foundation
import FSKit
import Darwin

let targetBundle = "io.macfuse.app.fsmodule.macfuse-local"
let semaphore = DispatchSemaphore(value: 0)

print("process_uid=\(getuid())")
print("process_euid=\(geteuid())")
print("process_gid=\(getgid())")
print("process_egid=\(getegid())")
print("process_user=\(NSUserName())")
print("home=\(NSHomeDirectory())")

FSClient.shared.fetchInstalledExtensions { identities, error in
    if let error = error {
        let ns = error as NSError
        print("query_status=error")
        print("error_domain=\(ns.domain)")
        print("error_code=\(ns.code)")
        print("error_description=\(ns.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
        semaphore.signal()
        return
    }

    let modules = identities ?? []
    print("query_status=ok")
    print("module_count=\(modules.count)")

    let sorted = modules.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    for module in sorted {
        let marker = module.bundleIdentifier == targetBundle ? "target" : "module"
        print("\(marker)_entry=\(module.bundleIdentifier)|enabled=\(module.isEnabled ? 1 : 0)|url=\(module.url.path)")
    }

    if let target = modules.first(where: { $0.bundleIdentifier == targetBundle }) {
        print("target_found=1")
        print("target_enabled=\(target.isEnabled ? 1 : 0)")
        print("target_url=\(target.url.path)")
    } else {
        print("target_found=0")
        print("target_enabled=unknown")
        print("target_url=unknown")
    }

    semaphore.signal()
}

if semaphore.wait(timeout: .now() + 10) == .timedOut {
    print("query_status=timeout")
    print("target_found=unknown")
    print("target_enabled=unknown")
    exit(124)
}
SWIFT

if ! /usr/bin/xcrun --sdk macosx swiftc -O -framework FSKit "$SWIFT_SRC" -o "$HELPER" >> "$REPORT" 2>&1; then
  log "helper_build=failed"
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
  log "Interpretation: PlugInKit may know the extension, but FSKit's own FSClient does not expose macfuse-local to the login user. This is direct evidence of a discovery/state split."
elif [[ "$USER_ENABLED" == "0" ]]; then
  log "RESULT=FSCLIENT_USER_REPORTS_DISABLED"
  log "Interpretation: FSKit's own public API reports macfuse-local disabled for the login user. If PlugInKit shows '+', the two state views are inconsistent; this is more specific than a final-mount-only authorization failure."
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "0" && "$ASUSER_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ENABLEMENT_DEPENDS_ON_USER_BOOTSTRAP"
  log "Interpretation: the same root EUID sees the module disabled in the normal sudo context but enabled when placed in the login user's launchd bootstrap. This strongly points to per-user agent/bootstrap state rather than code signing or EUID alone."
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "0" && "$BACKUSER_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ROOT_CONTEXT_REPORTS_DISABLED"
  log "Interpretation: FSKit reports the module enabled for UID $UID_NOW but disabled for root. This matches the root-only MFMount preflight warning and supports a per-user enablement/state source."
elif [[ "$USER_ENABLED" == "1" && "$ROOT_ENABLED" == "1" ]]; then
  log "RESULT=FSCLIENT_ENABLED_IN_USER_AND_ROOT"
  log "Interpretation: FSKit's public module state reports macfuse-local enabled in both primary contexts. Given the separately captured final mount requiresApproval failure, isEnabled alone is not the final LiveFiles mount-authorization predicate."
else
  log "RESULT=FSCLIENT_CONTEXT_MATRIX_MIXED"
  log "Interpretation: inspect the four context outputs. A mixed result can distinguish effective UID, login-user bootstrap and per-user fskit_agent state."
fi

log "REPORT=$REPORT"
exit 0
