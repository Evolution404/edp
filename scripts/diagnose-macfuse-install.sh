#!/bin/bash
set -u

REPORT="${TMPDIR:-/tmp}/edp-macfuse-install-report.txt"
: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }
run() { "$@" 2>&1 | tee -a "$REPORT" || true; }

section "System"
run /usr/bin/sw_vers
run /usr/bin/uname -m
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "macFUSE package receipts"
PKGS="$(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -i -E 'macfuse|osxfuse' || true)"
if [[ -z "$PKGS" ]]; then
  log "No macFUSE/osxfuse package receipts found"
else
  printf '%s\n' "$PKGS" | tee -a "$REPORT"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    log "--- $p ---"
    /usr/sbin/pkgutil --pkg-info "$p" 2>&1 | tee -a "$REPORT" || true
  done <<< "$PKGS"
fi

section "Known macFUSE plist versions"
PLISTS=(
  "/Library/Filesystems/macfuse.fs/Contents/Info.plist"
  "/Applications/macFUSE.app/Contents/Info.plist"
  "/Library/PreferencePanes/macFUSE.prefPane/Contents/Info.plist"
)
for p in "${PLISTS[@]}"; do
  if [[ -f "$p" ]]; then
    log "--- $p ---"
    for k in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
      v=$(/usr/libexec/PlistBuddy -c "Print :$k" "$p" 2>/dev/null || true)
      log "$k=${v:-<missing>}"
    done
  fi
done

section "libfuse"
if command -v pkg-config >/dev/null 2>&1; then
  log "pkg-config fuse version=$(pkg-config --modversion fuse 2>/dev/null || echo unknown)"
  log "pkg-config fuse libs=$(pkg-config --libs fuse 2>/dev/null || echo unknown)"
fi
for f in /usr/local/lib/libfuse*.dylib /opt/homebrew/lib/libfuse*.dylib; do
  [[ -e "$f" ]] || continue
  log "--- $f ---"
  run /usr/bin/otool -L "$f"
done

section "FSKit extension registration"
/usr/bin/pluginkit -m -A -D 2>&1 | /usr/bin/grep -i -C 5 macfuse | tee -a "$REPORT" || log "No macFUSE entries returned by pluginkit"

section "macFUSE processes"
/bin/ps ax -o pid,uid,gid,command | /usr/bin/grep -i macfuse | /usr/bin/grep -v grep | tee -a "$REPORT" || log "No macFUSE process currently running"

section "Launch service"
sudo /bin/launchctl print system/io.macfuse.app.launchservice.daemon 2>&1 | /usr/bin/head -n 120 | tee -a "$REPORT" || true

section "Recent macFUSE crash reports"
CRASH_LIST=$(
  sudo /usr/bin/find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports \
    -type f \( -iname '*macfuse*.ips' -o -iname '*macfuse*.crash' -o -iname '*fsmodule*.ips' -o -iname '*fsmodule*.crash' \) \
    -mmin -60 -print 2>/dev/null | /usr/bin/sort -u
)

if [[ -z "$CRASH_LIST" ]]; then
  log "No macFUSE/FSModule crash report found in the last 60 minutes"
else
  printf '%s\n' "$CRASH_LIST" | tee -a "$REPORT"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    log "--- crash summary: $f ---"
    sudo /usr/bin/grep -i -E 'procName|bundleInfo|exception|termination|faultingThread|signal|crashReporterKey|sip|codeSigning' "$f" 2>/dev/null | /usr/bin/head -n 80 | tee -a "$REPORT" || true
  done <<< "$CRASH_LIST"
fi

section "Recent macFUSE / FSKit errors"
/usr/bin/log show --debug --info \
  --predicate 'subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"}' \
  --last 10m 2>&1 | \
  /usr/bin/grep -i -E 'error|failed|invalidat|crash|fault|extension|activateVolume|MountError|MFMount' | \
  /usr/bin/tail -n 250 | tee -a "$REPORT" || true

section "SUMMARY"
if [[ -n "$CRASH_LIST" ]]; then
  log "RESULT=MACFUSE_FSKIT_CRASH_REPORT_FOUND"
  log "Interpretation: the FSKit extension or related macFUSE process produced a crash report; inspect the crash summary before reinstalling anything."
else
  log "RESULT=NO_RECENT_CRASH_REPORT"
  log "Interpretation: channel invalidation was observed without a recent macFUSE crash report; compare installed component versions and launch-service state."
fi
log "REPORT=$REPORT"
