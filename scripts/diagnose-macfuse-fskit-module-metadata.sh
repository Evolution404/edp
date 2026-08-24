#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-macfuse-fskit-module-metadata"
REPORT="$BASE/report.txt"
FSROOT="/Library/Filesystems/macfuse.fs"
APP="$FSROOT/Contents/Resources/macfuse.app"
LOCAL="$APP/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
GENERIC="$APP/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
GENERIC_ID="io.macfuse.app.fsmodule.macfuse"

mkdir -p "$BASE"
: > "$REPORT"
log(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
section(){ log ""; log "=== $* ==="; }

section "System and package"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true

section "Installed FSKit extension paths"
for p in "$LOCAL" "$GENERIC"; do
  log "path=$p"
  if [[ -d "$p" ]]; then
    /bin/ls -ldT "$p" 2>&1 | tee -a "$REPORT"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$p" 2>&1 | tee -a "$REPORT" || true
    log "sha256=$(/usr/bin/shasum -a 256 "$p/Contents/MacOS/$(basename "$p" .appex)" 2>/dev/null | /usr/bin/awk '{print $1}')"
  else
    log "MISSING"
  fi
done

section "Local Info.plist full"
if [[ -f "$LOCAL/Contents/Info.plist" ]]; then
  /usr/bin/plutil -p "$LOCAL/Contents/Info.plist" 2>&1 | tee -a "$REPORT"
fi

section "Generic Info.plist full"
if [[ -f "$GENERIC/Contents/Info.plist" ]]; then
  /usr/bin/plutil -p "$GENERIC/Contents/Info.plist" 2>&1 | tee -a "$REPORT"
fi

section "Local entitlements"
/usr/bin/codesign -d --entitlements :- "$LOCAL" 2>&1 | tee -a "$REPORT" || true

section "Generic entitlements"
/usr/bin/codesign -d --entitlements :- "$GENERIC" 2>&1 | tee -a "$REPORT" || true

section "PluginKit local record"
LOCAL_PK="$BASE/pluginkit-local.txt"
/usr/bin/pluginkit -m -A -D -i "$LOCAL_ID" 2>&1 | tee "$LOCAL_PK" | tee -a "$REPORT" || true

section "PluginKit generic record"
GENERIC_PK="$BASE/pluginkit-generic.txt"
/usr/bin/pluginkit -m -A -D -i "$GENERIC_ID" 2>&1 | tee "$GENERIC_PK" | tee -a "$REPORT" || true

section "Duplicate extension copies"
DUP="$BASE/duplicates.txt"
/usr/bin/find /Library /Applications "$HOME/Applications" \
  \( -name 'io.macfuse.app.fsmodule.macfuse-local.appex' -o -name 'io.macfuse.app.fsmodule.macfuse.appex' \) \
  -print 2>/dev/null | /usr/bin/sort -u | tee "$DUP" | tee -a "$REPORT" || true

section "macFUSE filesystem tree timestamps"
/usr/bin/find "$FSROOT/Contents" -maxdepth 5 \
  \( -name '*.appex' -o -name 'MFMount.framework' -o -name 'libfuse*.dylib' -o -name 'macfuse.app' \) \
  -exec /bin/ls -ldT {} \; 2>/dev/null | tee -a "$REPORT" || true

section "Recent fskit registration/resource events"
/usr/bin/log show --debug --info \
  --predicate '(process == "fskitd") OR (process == "fskit_agent") OR (process == "pkd") OR (subsystem == "com.apple.FSKit")' \
  --last 8m 2>&1 | /usr/bin/grep -i -E 'macfuse|fsmodule|module|resource|probe|addition|extension|bundle' | /usr/bin/tail -n 500 | tee -a "$REPORT" || true

LOCAL_PATH_OK=0
GENERIC_PATH_OK=0
LOCAL_ENT=0
GENERIC_ENT=0
LOCAL_DUP=0
GENERIC_DUP=0
LOCAL_PK_COUNT=0
GENERIC_PK_COUNT=0

/usr/bin/grep -F -q "$LOCAL" "$LOCAL_PK" 2>/dev/null && LOCAL_PATH_OK=1 || true
/usr/bin/grep -F -q "$GENERIC" "$GENERIC_PK" 2>/dev/null && GENERIC_PATH_OK=1 || true
/usr/bin/codesign -d --entitlements :- "$LOCAL" 2>&1 | /usr/bin/grep -q 'com.apple.developer.fskit.fsmodule' && LOCAL_ENT=1 || true
/usr/bin/codesign -d --entitlements :- "$GENERIC" 2>&1 | /usr/bin/grep -q 'com.apple.developer.fskit.fsmodule' && GENERIC_ENT=1 || true
LOCAL_DUP="$(/usr/bin/grep -c 'io.macfuse.app.fsmodule.macfuse-local.appex$' "$DUP" 2>/dev/null || true)"
GENERIC_DUP="$(/usr/bin/grep -c 'io.macfuse.app.fsmodule.macfuse.appex$' "$DUP" 2>/dev/null || true)"
LOCAL_PK_COUNT="$(/usr/bin/grep -c "$LOCAL_ID" "$LOCAL_PK" 2>/dev/null || true)"
GENERIC_PK_COUNT="$(/usr/bin/grep -c "$GENERIC_ID" "$GENERIC_PK" 2>/dev/null || true)"

section "SUMMARY"
log "local_plugin_path_ok=$LOCAL_PATH_OK generic_plugin_path_ok=$GENERIC_PATH_OK"
log "local_fskit_entitlement=$LOCAL_ENT generic_fskit_entitlement=$GENERIC_ENT"
log "local_extension_copy_count=$LOCAL_DUP generic_extension_copy_count=$GENERIC_DUP"
log "local_pluginkit_match_count=$LOCAL_PK_COUNT generic_pluginkit_match_count=$GENERIC_PK_COUNT"

if [[ "$LOCAL_PATH_OK" -eq 0 ]]; then
  log "RESULT=LOCAL_PLUGIN_RECORD_PATH_MISMATCH"
  log "Interpretation: PluginKit's macfuse-local record does not point at the currently installed extension. This can explain why the virtual block device is not matched as macFUSE after package version changes."
elif [[ "$LOCAL_ENT" -eq 0 ]]; then
  log "RESULT=LOCAL_FSKIT_ENTITLEMENT_MISSING"
  log "Interpretation: the installed macfuse-local extension lacks the FSKit module entitlement."
elif [[ "$LOCAL_DUP" -gt 1 || "$LOCAL_PK_COUNT" -gt 1 ]]; then
  log "RESULT=DUPLICATE_MACFUSE_FSKIT_REGISTRATION"
  log "Interpretation: multiple macfuse-local copies or PluginKit records exist. fskitd may be resolving stale module metadata."
else
  log "RESULT=MODULE_METADATA_LOOKS_CONSISTENT"
  log "Interpretation: the installed extension, entitlement and PluginKit path are internally consistent. The next target is the ephemeral virtual disk's FSKit additions/content hints rather than package registration."
fi
log "REPORT=$REPORT"
