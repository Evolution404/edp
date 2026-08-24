#!/bin/bash
set -u

REPORT="${TMPDIR:-/tmp}/edp-macfuse-virtual-device-report.txt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/edp-macfuse-virtual-device.XXXXXX")"
USER_IMG="$WORK/user.raw"
ROOT_IMG="$WORK/root.raw"
USER_OUT="$WORK/user-attach.txt"
ROOT_OUT="$WORK/root-attach.txt"
USER_DEV=""
ROOT_DEV=""

: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

cleanup() {
  if [[ -n "$USER_DEV" ]]; then
    hdiutil detach "$USER_DEV" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ROOT_DEV" ]]; then
    sudo hdiutil detach "$ROOT_DEV" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

extract_device() {
  awk '/^\/dev\/disk[0-9]+/ {print $1; exit}' "$1"
}

section "System"
sw_vers | tee -a "$REPORT"
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "macFUSE version"
pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true

HELPER="/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon"
section "macFUSE privileged helper signature"
if [[ -x "$HELPER" ]]; then
  codesign --verify --verbose=4 "$HELPER" 2>&1 | tee -a "$REPORT" || true
  codesign -dv --verbose=4 "$HELPER" 2>&1 | tee -a "$REPORT" || true
  codesign -d --entitlements :- "$HELPER" 2>&1 | tee -a "$REPORT" || true
  spctl --assess --type execute -vv "$HELPER" 2>&1 | tee -a "$REPORT" || true
else
  log "helper_missing=1"
fi

section "DiskImages / Disk Arbitration processes"
ps -axo pid,ppid,user,lstart,command | grep -E '[d]iskimages|[d]iskarbitrationd|[h]diutil' | tee -a "$REPORT" || true

section "Create raw images"
dd if=/dev/zero of="$USER_IMG" bs=1 count=0 seek=8388608 2>&1 | tee -a "$REPORT"
dd if=/dev/zero of="$ROOT_IMG" bs=1 count=0 seek=8388608 2>&1 | tee -a "$REPORT"
ls -lh "$USER_IMG" "$ROOT_IMG" | tee -a "$REPORT"

section "User-context CRawDiskImage attach"
set +e
hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$USER_IMG" >"$USER_OUT" 2>&1
USER_RC=$?
set -e
cat "$USER_OUT" | tee -a "$REPORT"
USER_DEV="$(extract_device "$USER_OUT")"
log "user_attach_rc=$USER_RC user_device=${USER_DEV:-none}"
if [[ -n "$USER_DEV" ]]; then
  diskutil info "$USER_DEV" 2>&1 | tee -a "$REPORT" || true
  set +e
  hdiutil detach "$USER_DEV" 2>&1 | tee -a "$REPORT"
  USER_DETACH_RC=${PIPESTATUS[0]}
  set -e
  log "user_detach_rc=$USER_DETACH_RC"
  if [[ "$USER_DETACH_RC" -eq 0 ]]; then USER_DEV=""; fi
else
  USER_DETACH_RC=99
fi

section "Root-context CRawDiskImage attach"
sudo -v
set +e
sudo hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$ROOT_IMG" >"$ROOT_OUT" 2>&1
ROOT_RC=$?
set -e
cat "$ROOT_OUT" | tee -a "$REPORT"
ROOT_DEV="$(extract_device "$ROOT_OUT")"
log "root_attach_rc=$ROOT_RC root_device=${ROOT_DEV:-none}"
if [[ -n "$ROOT_DEV" ]]; then
  sudo diskutil info "$ROOT_DEV" 2>&1 | tee -a "$REPORT" || true
  set +e
  sudo hdiutil detach "$ROOT_DEV" 2>&1 | tee -a "$REPORT"
  ROOT_DETACH_RC=${PIPESTATUS[0]}
  set -e
  log "root_detach_rc=$ROOT_DETACH_RC"
  if [[ "$ROOT_DETACH_RC" -eq 0 ]]; then ROOT_DEV=""; fi
else
  ROOT_DETACH_RC=99
fi

section "Recent DiskImages / macFUSE logs"
/usr/bin/log show --debug --info \
  --predicate '(process CONTAINS[c] "diskimage") OR (process == "diskarbitrationd") OR (subsystem == "io.macfuse") OR (eventMessage CONTAINS[c] "virtual device") OR (eventMessage CONTAINS[c] "DiskImage")' \
  --last 5m 2>&1 | tail -n 350 | tee -a "$REPORT" || true

section "SUMMARY"
log "user_attach_rc=$USER_RC root_attach_rc=$ROOT_RC user_detach_rc=$USER_DETACH_RC root_detach_rc=$ROOT_DETACH_RC"
if [[ "$USER_RC" -eq 0 && "$ROOT_RC" -eq 0 ]]; then
  log "RESULT=RAW_DISKIMAGE_OK_MACFUSE_INTERNAL_ACTIVATION_FAIL"
  log "Interpretation: macOS can create and detach CRawDiskImage devices in both user and root contexts. The failure is inside macFUSE's own local virtual-device activation path or its specific parameters/entitlements."
elif [[ "$USER_RC" -eq 0 && "$ROOT_RC" -ne 0 ]]; then
  log "RESULT=ROOT_DISKIMAGE_CONTEXT_FAIL"
  log "Interpretation: DiskImages works for the login user but fails in root context, matching macFUSE's privileged mount-service path closely."
elif [[ "$USER_RC" -ne 0 && "$ROOT_RC" -eq 0 ]]; then
  log "RESULT=USER_DISKIMAGE_CONTEXT_FAIL"
  log "Interpretation: root can create the raw virtual device but the login user cannot."
else
  log "RESULT=SYSTEM_RAW_DISKIMAGE_ACTIVATION_FAIL"
  log "Interpretation: even direct CRawDiskImage activation fails outside macFUSE, pointing to the macOS DiskImages subsystem."
fi
log "REPORT=$REPORT"
