#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-macfuse-virtual-device"
REPORT="$BASE/report.txt"
LIVE_LOG="$BASE/live.log"
ISSUE_JSON="$BASE/issue-1181.json"
MINFS_C="$BASE/minfs.c"
MINFS_BIN="$BASE/minfs"
MINFS_LOG="$BASE/minfs.log"
MOUNT_POINT="/Volumes/edp-minfs-device-diag"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
LOG_PID=""
MINFS_PID=""

mkdir -p "$BASE"
: > "$REPORT"
: > "$LIVE_LOG"
: > "$MINFS_LOG"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

cleanup() {
  if [[ -n "$MINFS_PID" ]] && kill -0 "$MINFS_PID" >/dev/null 2>&1; then
    kill "$MINFS_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    sudo kill "$LOG_PID" >/dev/null 2>&1 || true
  fi
  if /sbin/mount | /usr/bin/grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
    /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || sudo /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  sudo /bin/rm -rf "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/bin/uname -m 2>&1 | tee -a "$REPORT"
log "uid=$UID_NOW gid=$GID_NOW user=$(id -un)"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true

section "macFUSE local mount error mapping"
log "MFDaemon.MountError Code=4 = activatingDeviceFailed"
log "This means creation/activation/initialization of the virtual volume used by macfuse-local failed."

section "Before: disk and image state"
/usr/sbin/diskutil list 2>&1 | tee -a "$REPORT" || true
/usr/bin/hdiutil info 2>&1 | tee -a "$REPORT" || true
/bin/ls -l /dev/disk* 2>/dev/null | tee -a "$REPORT" || true

section "macFUSE launch daemon binary strings"
DAEMON="/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon"
if [[ -x "$DAEMON" ]]; then
  /usr/bin/strings -a "$DAEMON" 2>/dev/null | /usr/bin/grep -i -E 'disk.?image|virtual device|activate|attach|detach|initialize|mount error|DiskArbitration|block device' | /usr/bin/head -n 250 | tee -a "$REPORT" || true
else
  log "launch_daemon_missing=1"
fi

section "Build exact issue-1181 minfs"
if ! /usr/bin/curl -fsSL https://api.github.com/repos/macfuse/macfuse/issues/1181 -o "$ISSUE_JSON"; then
  log "RESULT=ISSUE_FETCH_FAILED"
  log "REPORT=$REPORT"
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
  log "RESULT=MINFS_EXTRACT_FAILED"
  log "REPORT=$REPORT"
  exit 2
fi

if ! /usr/bin/cc -o "$MINFS_BIN" "$MINFS_C" -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26 -I/usr/local/include -L/usr/local/lib -lfuse >> "$REPORT" 2>&1; then
  log "RESULT=MINFS_BUILD_FAILED"
  log "REPORT=$REPORT"
  exit 2
fi

/usr/bin/otool -L "$MINFS_BIN" 2>&1 | tee -a "$REPORT" || true

section "Prepare mount point"
sudo -v
if /sbin/mount | /usr/bin/grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
  sudo /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
fi
sudo /bin/rm -rf "$MOUNT_POINT"
sudo /bin/mkdir "$MOUNT_POINT"
sudo /usr/sbin/chown "$UID_NOW:$GID_NOW" "$MOUNT_POINT"
/bin/chmod 700 "$MOUNT_POINT"

section "Start virtual-device focused live log"
sudo /usr/bin/log stream --style compact --level debug \
  --predicate '(subsystem IN {"io.macfuse","com.apple.FSKit","com.apple.LiveFS","com.apple.DiskArbitration","com.apple.DiskImages2","com.apple.diskimages"}) OR (process IN {"io.macfuse.app.launchservice.daemon","diskarbitrationd","diskimages-helper","diskimagesiod","diskmanagementd","storagekitd","fskitd","fskit_agent","kernel"})' \
  > "$LIVE_LOG" 2>&1 &
LOG_PID=$!
sleep 1

section "Run exact minfs"
log "command=$MINFS_BIN -f -o backend=fskit,uid=$UID_NOW,gid=$GID_NOW $MOUNT_POINT"
"$MINFS_BIN" -f -o "backend=fskit,uid=$UID_NOW,gid=$GID_NOW" "$MOUNT_POINT" > "$MINFS_LOG" 2>&1 &
MINFS_PID=$!
log "minfs_pid=$MINFS_PID"

for _ in $(seq 1 60); do
  if [[ -r "$MOUNT_POINT/small.sh" ]]; then
    break
  fi
  if ! kill -0 "$MINFS_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

sleep 1

MINFS_RUNNING=0
MINFS_RC="running"
if kill -0 "$MINFS_PID" >/dev/null 2>&1; then
  MINFS_RUNNING=1
else
  set +e
  wait "$MINFS_PID"
  MINFS_RC=$?
  set -e
fi

section "During/after: disk and image state"
/usr/sbin/diskutil list 2>&1 | tee -a "$REPORT" || true
/usr/bin/hdiutil info 2>&1 | tee -a "$REPORT" || true
/bin/ls -l /dev/disk* 2>/dev/null | tee -a "$REPORT" || true
/sbin/mount 2>&1 | /usr/bin/grep -i -E 'macfuse|edp-minfs-device-diag' | tee -a "$REPORT" || true

section "minfs log"
/bin/cat "$MINFS_LOG" 2>&1 | tee -a "$REPORT" || true

if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
  sudo kill "$LOG_PID" >/dev/null 2>&1 || true
  sleep 0.5
fi

section "Virtual-device lifecycle"
/usr/bin/grep -i -E 'virtual|disk.?image|attach|detach|activate|deactivate|initialize|block device|FSBlockDevice|DiskArbitration|DADisk|MFDaemon|MountError|mount volume|device' "$LIVE_LOG" | /usr/bin/tail -n 650 | tee -a "$REPORT" || true

section "macFUSE daemon errors only"
/usr/bin/grep -i -E 'io.macfuse.app.launchservice.daemon.*(error|failed|MountError|DiskImage|device|attach|detach|activate|initialize)' "$LIVE_LOG" | /usr/bin/tail -n 250 | tee -a "$REPORT" || true

section "Disk Arbitration / DiskImages errors only"
/usr/bin/grep -i -E '(diskarbitrationd|diskimages-helper|diskimagesiod|diskmanagementd|storagekitd).*(error|fail|denied|timeout|unable|invalid|busy|not found|no such)' "$LIVE_LOG" | /usr/bin/tail -n 250 | tee -a "$REPORT" || true

CHANNEL_CREATED=0
ACTIVATE_OK=0
MOUNT_ERROR4=0
DISKIMAGE_ERROR=0
DA_ERROR=0
MOUNT8_ERROR=0
VIRTUAL_DEVICE_EVENT=0

/usr/bin/grep -q 'Channel created' "$LIVE_LOG" && CHANNEL_CREATED=1 || true
/usr/bin/grep -E -q 'activateVolume.*error:0|activate volume .* found root item' "$LIVE_LOG" && ACTIVATE_OK=1 || true
/usr/bin/grep -E -q 'MFDaemon\.MountError Code=4' "$LIVE_LOG" "$MINFS_LOG" 2>/dev/null && MOUNT_ERROR4=1 || true
/usr/bin/grep -E -q 'MFDaemon\.DiskImage\.Error|Failed to (attach|detach|activate|initialize) virtual device' "$LIVE_LOG" 2>/dev/null && DISKIMAGE_ERROR=1 || true
/usr/bin/grep -i -E -q '(diskarbitrationd|DiskArbitration).*(error|fail|denied|timeout|unable|busy)' "$LIVE_LOG" 2>/dev/null && DA_ERROR=1 || true
/usr/bin/grep -i -E -q 'mount\(8\).*returned|Failed to call mount\(8\)' "$LIVE_LOG" "$MINFS_LOG" 2>/dev/null && MOUNT8_ERROR=1 || true
/usr/bin/grep -i -E -q 'virtual device|disk.?image|FSBlockDeviceResource|block device' "$LIVE_LOG" 2>/dev/null && VIRTUAL_DEVICE_EVENT=1 || true

section "SUMMARY"
log "minfs_running=$MINFS_RUNNING minfs_rc=$MINFS_RC channel_created=$CHANNEL_CREATED activate_ok=$ACTIVATE_OK mount_error4=$MOUNT_ERROR4 diskimage_error=$DISKIMAGE_ERROR disk_arbitration_error=$DA_ERROR mount8_error=$MOUNT8_ERROR virtual_device_event=$VIRTUAL_DEVICE_EVENT"

if [[ "$CHANNEL_CREATED" -eq 1 && "$ACTIVATE_OK" -eq 1 && "$MOUNT_ERROR4" -eq 1 && "$DISKIMAGE_ERROR" -eq 1 ]]; then
  log "RESULT=VIRTUAL_DEVICE_DISKIMAGE_FAILURE"
  log "Interpretation: FUSE/FSKit channel creation and activateVolume succeeded. The local backend then failed in macFUSE's virtual disk-image/device lifecycle and rolled the volume back. Inspect the DiskImage error lines above."
elif [[ "$CHANNEL_CREATED" -eq 1 && "$ACTIVATE_OK" -eq 1 && "$MOUNT_ERROR4" -eq 1 && "$DA_ERROR" -eq 1 ]]; then
  log "RESULT=VIRTUAL_DEVICE_DISK_ARBITRATION_FAILURE"
  log "Interpretation: the FSKit volume activated, but Disk Arbitration failed while macFUSE was activating the local virtual device. Inspect the Disk Arbitration lines above."
elif [[ "$CHANNEL_CREATED" -eq 1 && "$ACTIVATE_OK" -eq 1 && "$MOUNT_ERROR4" -eq 1 ]]; then
  log "RESULT=VIRTUAL_DEVICE_ACTIVATION_FAILED_NO_PUBLIC_SUBERROR"
  log "Interpretation: macFUSE conclusively reports activatingDeviceFailed after a successful FSKit channel/activateVolume, but no lower-level public subsystem error was emitted. The failure is inside the local virtual-volume activation path, not EDP or FUSE callbacks."
elif [[ "$MOUNT8_ERROR" -eq 1 ]]; then
  log "RESULT=MOUNT_COMMAND_STAGE_FAILURE"
  log "Interpretation: the virtual device progressed far enough for the system mount command, which then failed. Inspect the mount(8) status and mountpoint state."
else
  log "RESULT=VIRTUAL_DEVICE_DIAG_INCONCLUSIVE"
  log "Interpretation: inspect the lifecycle and daemon sections above; the observed sequence differs from the previous Code=4 path."
fi

log "REPORT=$REPORT"
exit 0
