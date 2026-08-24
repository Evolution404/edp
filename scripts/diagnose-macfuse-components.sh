#!/bin/bash
set -u

REPORT="${TMPDIR:-/tmp}/edp-macfuse-components-report.txt"
: > "$REPORT"

log(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
section(){ log ""; log "=== $* ==="; }

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/bin/uname -m 2>&1 | tee -a "$REPORT"

section "Package receipts"
PKGS="$(/usr/sbin/pkgutil --pkgs | /usr/bin/grep -i macfuse || true)"
if [[ -z "$PKGS" ]]; then
  log "No macFUSE pkg receipts found"
else
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    log "--- $p ---"
    /usr/sbin/pkgutil --pkg-info "$p" 2>&1 | tee -a "$REPORT" || true
  done <<< "$PKGS"
fi

ROOT="/Library/Filesystems/macfuse.fs"
section "macfuse.fs root"
if [[ -d "$ROOT" ]]; then
  /bin/ls -ld "$ROOT" | tee -a "$REPORT"
  /usr/bin/stat -f 'mtime=%Sm owner=%Su:%Sg mode=%Sp' -t '%Y-%m-%d %H:%M:%S' "$ROOT" | tee -a "$REPORT"
else
  log "MISSING: $ROOT"
fi

section "Bundle versions"
/usr/bin/find "$ROOT" -name Info.plist -type f 2>/dev/null | while IFS= read -r plist; do
  BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)
  VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)
  BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)
  if [[ "$BID" == *macfuse* || "$plist" == *MFMount.framework* || "$plist" == *macfuse.fs* ]]; then
    log "$plist"
    log "  id=$BID version=$VER build=$BUILD"
  fi
done

section "Swift compatibility libraries"
SWIFT_COUNT=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  SWIFT_COUNT=$((SWIFT_COUNT+1))
  log "$f"
  /usr/bin/shasum -a 256 "$f" 2>&1 | tee -a "$REPORT" || true
done < <(/usr/bin/find "$ROOT" -name 'libswiftCompatibilitySpan.dylib' -type f 2>/dev/null)
log "swiftCompatibilitySpan_count=$SWIFT_COUNT"

section "MFMount dependencies"
MFMOUNT="$(/usr/bin/find "$ROOT" -path '*MFMount.framework*' -type f -name MFMount 2>/dev/null | /usr/bin/head -1)"
if [[ -n "$MFMOUNT" ]]; then
  log "$MFMOUNT"
  /usr/bin/otool -L "$MFMOUNT" 2>&1 | tee -a "$REPORT"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$MFMOUNT" 2>&1 | tee -a "$REPORT" || true
else
  log "MISSING: MFMount binary"
fi

section "libfuse libraries"
for f in /usr/local/lib/libfuse*.dylib /opt/homebrew/lib/libfuse*.dylib; do
  [[ -e "$f" ]] || continue
  log "$f"
  /usr/bin/otool -D "$f" 2>&1 | tee -a "$REPORT" || true
  /usr/bin/otool -L "$f" 2>&1 | tee -a "$REPORT" || true
  /usr/bin/shasum -a 256 "$f" 2>&1 | tee -a "$REPORT" || true
done

section "FSKit extension bundles"
/usr/bin/find "$ROOT" \( -name '*.appex' -o -name '*.fskit' \) -type d 2>/dev/null | while IFS= read -r b; do
  log "$b"
  if [[ -f "$b/Contents/Info.plist" ]]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$b/Contents/Info.plist" 2>/dev/null | sed 's/^/  id=/' | tee -a "$REPORT" || true
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$b/Contents/Info.plist" 2>/dev/null | sed 's/^/  version=/' | tee -a "$REPORT" || true
  fi
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$b" 2>&1 | tee -a "$REPORT" || true
done

section "PluginKit macFUSE records"
/usr/bin/pluginkit -m -A -D -v 2>&1 | /usr/bin/grep -i -C 5 macfuse | tee -a "$REPORT" || log "No macFUSE PluginKit records"

section "Running macFUSE processes"
/bin/ps -axo pid,ppid,user,lstart,command | /usr/bin/grep -i '[m]acfuse' | tee -a "$REPORT" || log "No running macFUSE processes"

section "Launch services"
for label in io.macfuse.app.launchservice.daemon io.macfuse.app.launchservice.agent; do
  log "--- $label ---"
  /bin/launchctl print "system/$label" 2>&1 | /usr/bin/head -80 | tee -a "$REPORT" || true
done

section "Recent dyld / macFUSE errors"
/usr/bin/log show --debug --info --last 15m \
  --predicate '(process CONTAINS[c] "macfuse" OR senderImagePath CONTAINS[c] "macfuse" OR eventMessage CONTAINS[c] "macfuse" OR eventMessage CONTAINS[c] "libswiftCompatibilitySpan") AND (messageType == error OR messageType == fault)' \
  2>&1 | /usr/bin/tail -n 200 | tee -a "$REPORT" || true

section "SUMMARY"
if [[ ! -d "$ROOT" ]]; then
  log "RESULT=MACFUSE_ROOT_MISSING"
elif [[ "$SWIFT_COUNT" -eq 0 ]]; then
  log "RESULT=SWIFT_COMPAT_LIBRARY_MISSING"
  log "Interpretation: macOS 15 requires the Swift compatibility library for macFUSE 5.3.x FSKit components; this strongly suggests an incomplete or mixed installation."
elif [[ -z "$MFMOUNT" ]]; then
  log "RESULT=MFMOUNT_MISSING"
else
  RECEIPT_VERSIONS="$(while IFS= read -r p; do /usr/sbin/pkgutil --pkg-info "$p" 2>/dev/null | awk '/version:/{print $2}'; done <<< "$PKGS" | sort -u | tr '\n' ' ')"
  log "receipt_versions=$RECEIPT_VERSIONS"
  log "RESULT=COMPONENTS_PRESENT_NEEDS_REVIEW"
  log "Interpretation: required component families are present; compare receipt/bundle versions and actual launch-service paths above for stale or mixed components."
fi
log "REPORT=$REPORT"
