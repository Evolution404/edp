#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-macfuse-virtual-disk-identity"
REPORT="$BASE/report.txt"
LIVE_LOG="$BASE/live.log"
ISSUE_JSON="$BASE/issue-1181.json"
MINFS_C="$BASE/minfs.c"
MINFS_BIN="$BASE/minfs"
MNT="/Volumes/edp-minfs-disk-identity"
MINFS_LOG="$BASE/minfs.log"
BEFORE="$BASE/disks-before.txt"
SEEN="$BASE/disks-seen.txt"
LOG_PID=""
MINFS_PID=""
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"

mkdir -p "$BASE"
: > "$REPORT"
: > "$LIVE_LOG"
: > "$MINFS_LOG"
: > "$SEEN"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

whole_disks() {
  /bin/ls /dev/disk[0-9]* 2>/dev/null | /usr/bin/sed -E 's#^/dev/(disk[0-9]+).*#\1#' | /usr/bin/sort -u
}

cleanup() {
  if [[ -n "$MINFS_PID" ]] && kill -0 "$MINFS_PID" >/dev/null 2>&1; then kill "$MINFS_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo kill "$LOG_PID" >/dev/null 2>&1 || true; fi
  if /sbin/mount | /usr/bin/grep -F " on $MNT " >/dev/null 2>&1; then /sbin/umount "$MNT" >/dev/null 2>&1 || sudo /sbin/umount "$MNT" >/dev/null 2>&1 || true; fi
  sudo /bin/rm -rf "$MNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

section "System and third-party filesystem bundles"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true
/bin/ls -ld /Library/Filesystems/* 2>&1 | tee -a "$REPORT" || true
IBOYSOFT_PRESENT=0
if [[ -d /Library/Filesystems/iboysoft_NTFS.fs ]]; then IBOYSOFT_PRESENT=1; fi
log "iboysoft_bundle_present=$IBOYSOFT_PRESENT"
/sbin/mount | /usr/bin/grep -i iboysoft | tee -a "$REPORT" || true

section "Disk state before test"
whole_disks > "$BEFORE"
/bin/cat "$BEFORE" | tee -a "$REPORT"
/usr/sbin/diskutil list 2>&1 | tee -a "$REPORT" || true
/usr/bin/hdiutil info 2>&1 | tee -a "$REPORT" || true

section "Build exact minfs from macFUSE issue 1181"
if ! /usr/bin/curl -fsSL https://api.github.com/repos/macfuse/macfuse/issues/1181 -o "$ISSUE_JSON"; then
  log "RESULT=FETCH_ISSUE_FAILED"
  exit 2
fi
if ! /usr/bin/python3 - "$ISSUE_JSON" "$MINFS_C" <<'PY'
import json, re, sys
src, out = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    body = json.load(f)['body']
m = re.search(r'```c\n(.*?)\n```', body, re.S)
if not m:
    raise SystemExit(2)
with open(out, 'w', encoding='utf-8') as f:
    f.write(m.group(1))
PY
then
  log "RESULT=EXTRACT_MINFS_FAILED"
  exit 2
fi
if ! /usr/bin/cc -o "$MINFS_BIN" "$MINFS_C" -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26 -I/usr/local/include -L/usr/local/lib -lfuse >> "$REPORT" 2>&1; then
  log "RESULT=BUILD_MINFS_FAILED"
  exit 2
fi

sudo -v
sudo /bin/rm -rf "$MNT"
sudo /bin/mkdir "$MNT"
sudo /usr/sbin/chown "$UID_NOW:$GID_NOW" "$MNT"
/bin/chmod 700 "$MNT"

section "Start focused live log"
sudo /usr/bin/log stream --style compact --level debug \
  --predicate '(subsystem IN {"io.macfuse","com.apple.DiskArbitration.diskarbitrationd","com.apple.diskimages","com.apple.DiskImages2"}) OR (process IN {"io.macfuse.app.launchservice.daemon","diskarbitrationd","diskimages-helper","diskimagesiod"})' \
  > "$LIVE_LOG" 2>&1 &
LOG_PID=$!
sleep 1

section "Run minfs while sampling device nodes"
"$MINFS_BIN" -f -o "backend=fskit,uid=$UID_NOW,gid=$GID_NOW" "$MNT" > "$MINFS_LOG" 2>&1 &
MINFS_PID=$!
log "minfs_pid=$MINFS_PID"

for _ in $(seq 1 120); do
  whole_disks >> "$SEEN"
  sleep 0.03
done
/usr/bin/sort -u "$SEEN" -o "$SEEN"

sleep 0.5
if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo kill "$LOG_PID" >/dev/null 2>&1 || true; fi
sleep 0.3

section "Disk identity correlation"
log "before_disks=$(tr '\n' ',' < "$BEFORE" | sed 's/,$//')"
log "seen_disks=$(tr '\n' ',' < "$SEEN" | sed 's/,$//')"
NEW_DISKS="$BASE/new-disks.txt"
/usr/bin/comm -13 "$BEFORE" "$SEEN" > "$NEW_DISKS" || true
log "new_disk_candidates=$(tr '\n' ',' < "$NEW_DISKS" | sed 's/,$//')"

IBOYSOFT_ON_NEW=0
ANY_PROBE_ON_NEW=0
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  if /usr/bin/grep -F "/dev/$d" "$LIVE_LOG" >/dev/null 2>&1; then
    ANY_PROBE_ON_NEW=1
    log "--- events for /dev/$d ---"
    /usr/bin/grep -F "/dev/$d" "$LIVE_LOG" | tee -a "$REPORT" || true
    if /usr/bin/grep -F "/dev/$d" "$LIVE_LOG" | /usr/bin/grep -i iboysoft_NTFS >/dev/null 2>&1; then
      IBOYSOFT_ON_NEW=1
    fi
  fi
done < "$NEW_DISKS"

section "macFUSE virtual-device lifecycle"
/usr/bin/grep -i -E 'Activate virtual device|Activated device|Deactivating virtual device|Detach virtual device|MountError Code=4|DiskImage.Error' "$LIVE_LOG" | tee -a "$REPORT" || true

section "All Disk Arbitration probe lines"
/usr/bin/grep -i -E 'probed disk|unable to probe' "$LIVE_LOG" | tee -a "$REPORT" || true

section "minfs log"
/bin/cat "$MINFS_LOG" | tee -a "$REPORT" || true

NEW_COUNT=$(/usr/bin/wc -l < "$NEW_DISKS" | /usr/bin/tr -d ' ')
CHANNEL_CREATED=0
MOUNT_ERROR4=0
if /usr/bin/grep -E -q 'Channel created|Connection to file system extension established' "$LIVE_LOG"; then CHANNEL_CREATED=1; fi
if /usr/bin/grep -q 'MFDaemon.MountError Code=4' "$LIVE_LOG"; then MOUNT_ERROR4=1; fi

section "SUMMARY"
log "new_disk_count=$NEW_COUNT iboysoft_bundle_present=$IBOYSOFT_PRESENT iboysoft_probe_on_new_disk=$IBOYSOFT_ON_NEW any_probe_on_new_disk=$ANY_PROBE_ON_NEW channel_created=$CHANNEL_CREATED mount_error4=$MOUNT_ERROR4"
if [[ "$NEW_COUNT" -gt 0 && "$IBOYSOFT_ON_NEW" -eq 1 ]]; then
  log "RESULT=VIRTUAL_DISK_CONFIRMED_IBOYSOFT_PROBE"
  log "Interpretation: a disk device appeared only during the macFUSE local mount attempt, and Disk Arbitration sent that new device through the iBoysoft_NTFS probe. This makes iBoysoft a concrete interference candidate; perform a reversible A/B test with the iBoysoft filesystem bundle temporarily disabled before changing EDP."
elif [[ "$NEW_COUNT" -gt 0 && "$ANY_PROBE_ON_NEW" -eq 1 ]]; then
  log "RESULT=VIRTUAL_DISK_CONFIRMED_NO_IBOYSOFT_ON_NEW"
  log "Interpretation: the newly created macFUSE virtual disk was captured and probed, but iBoysoft was not involved with that device. Focus on the exact probe/activation failure for the new disk instead."
elif [[ "$NEW_COUNT" -gt 0 ]]; then
  log "RESULT=VIRTUAL_DISK_CAPTURED_WITHOUT_PROBE_LOG"
  log "Interpretation: a new disk node was observed during the mount, but no matching Disk Arbitration probe line was captured. Increase correlation logging before blaming third-party filesystem probes."
else
  log "RESULT=VIRTUAL_DISK_ID_NOT_CAPTURED"
  log "Interpretation: no new whole-disk node was captured during the short activation window. The /dev/disk4 probe lines from the previous run cannot yet be attributed to macFUSE's virtual disk."
fi
log "REPORT=$REPORT"
