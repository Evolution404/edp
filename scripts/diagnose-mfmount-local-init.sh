#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-mfmount-local-init"
REPORT="$BASE/report.txt"
LIVE_LOG="$BASE/live.log"
STRINGS_LOG="$BASE/daemon-strings.txt"
BEFORE_DISKS="$BASE/before-disks.txt"
NEW_DISK_FILE="$BASE/new-disk.txt"
DISKINFO="$BASE/new-disk-info.txt"
DISKINFO_PLIST="$BASE/new-disk-info.plist"
IOREG="$BASE/ioreg-iomedia.plist"
HDIINFO="$BASE/hdiutil-info.txt"
ISSUE_JSON="$BASE/issue-1181.json"
MINFS_C="$BASE/minfs.c"
MINFS_BIN="$BASE/minfs"
MINFS_LOG="$BASE/minfs.log"
MNT="/Volumes/edp-mfmount-init"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
LOG_PID=""
WATCH_PID=""
MINFS_PID=""

mkdir -p "$BASE"
: > "$REPORT"
: > "$LIVE_LOG"
: > "$STRINGS_LOG"
: > "$NEW_DISK_FILE"
: > "$DISKINFO"
: > "$MINFS_LOG"

log(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
section(){ log ""; log "=== $* ==="; }

cleanup_mount(){
  if /sbin/mount | /usr/bin/grep -F " on $MNT " >/dev/null 2>&1; then
    /sbin/umount "$MNT" >/dev/null 2>&1 || sudo /sbin/umount "$MNT" >/dev/null 2>&1 || true
  fi
  sudo /bin/rm -rf "$MNT" >/dev/null 2>&1 || true
}

cleanup(){
  if [[ -n "$MINFS_PID" ]] && kill -0 "$MINFS_PID" >/dev/null 2>&1; then kill "$MINFS_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$WATCH_PID" ]] && kill -0 "$WATCH_PID" >/dev/null 2>&1; then kill "$WATCH_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo /bin/kill "$LOG_PID" >/dev/null 2>&1 || true; fi
  cleanup_mount
}
trap cleanup EXIT INT TERM

whole_disks(){
  /bin/ls /dev/disk* 2>/dev/null | /usr/bin/grep -E '^/dev/disk[0-9]+$' | /usr/bin/sed 's#^/dev/##' | /usr/bin/sort -V
}

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true
log "uid=$UID_NOW gid=$GID_NOW user=$(id -un)"

section "Locate macFUSE mount-service daemon"
DAEMON_PID="$(/usr/bin/pgrep -x io.macfuse.app.launchservice.daemon | /usr/bin/head -n 1 || true)"
DAEMON_BIN=""
if [[ -n "$DAEMON_PID" ]]; then
  DAEMON_BIN="$(/usr/sbin/lsof -a -p "$DAEMON_PID" -d txt -Fn 2>/dev/null | /usr/bin/sed -n 's/^n//p' | /usr/bin/head -n 1 || true)"
fi
if [[ -z "$DAEMON_BIN" || ! -f "$DAEMON_BIN" ]]; then
  DAEMON_BIN="$(/usr/bin/find /Library/PrivilegedHelperTools /Library/Filesystems/macfuse.fs -type f -name 'io.macfuse.app.launchservice.daemon' -print 2>/dev/null | /usr/bin/head -n 1 || true)"
fi
log "daemon_pid=${DAEMON_PID:-not-running}"
log "daemon_bin=${DAEMON_BIN:-not-found}"
if [[ -n "$DAEMON_BIN" && -f "$DAEMON_BIN" ]]; then
  /usr/bin/codesign --verify --strict --verbose=2 "$DAEMON_BIN" 2>&1 | tee -a "$REPORT" || true
  /usr/bin/strings -a "$DAEMON_BIN" 2>/dev/null | /usr/bin/grep -i -E 'virtual device|disk ?image|MFDaemon|activate|initializ|attach|detach|mount volume|failed to' | /usr/bin/sort -u > "$STRINGS_LOG" || true
fi

section "Relevant mount-service strings"
/usr/bin/cat "$STRINGS_LOG" | /usr/bin/tail -n 250 | tee -a "$REPORT" || true

section "Build exact issue-1181 minfs"
if ! /usr/bin/curl -fsSL https://api.github.com/repos/macfuse/macfuse/issues/1181 -o "$ISSUE_JSON"; then
  log "issue_fetch_failed=1"
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
  log "minfs_extract_failed=1"
  exit 2
fi
if ! /usr/bin/cc -O0 -o "$MINFS_BIN" "$MINFS_C" -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26 -I/usr/local/include -L/usr/local/lib -lfuse >> "$REPORT" 2>&1; then
  log "minfs_build_failed=1"
  exit 2
fi

cleanup_mount
sudo /bin/mkdir "$MNT"
sudo /usr/sbin/chown "$UID_NOW:$GID_NOW" "$MNT"
/bin/chmod 700 "$MNT"

whole_disks > "$BEFORE_DISKS"
section "Whole disks before mount"
/usr/bin/cat "$BEFORE_DISKS" | tee -a "$REPORT"

sudo -v
section "Start focused live log"
sudo /usr/bin/log stream --style compact --level debug --source \
  --predicate '(subsystem IN {"io.macfuse","com.apple.FSKit","com.apple.DiskArbitration","com.apple.DiskImages2","com.apple.diskimages"}) OR (process IN {"io.macfuse.app.launchservice.daemon","diskarbitrationd","diskimages-helper","diskimagesiod","fskitd","fskit_agent"})' \
  > "$LIVE_LOG" 2>&1 &
LOG_PID=$!
sleep 1
if ! kill -0 "$LOG_PID" >/dev/null 2>&1; then
  sudo /usr/bin/log stream --style compact --level debug \
    --predicate '(subsystem IN {"io.macfuse","com.apple.FSKit","com.apple.DiskArbitration","com.apple.DiskImages2","com.apple.diskimages"}) OR (process IN {"io.macfuse.app.launchservice.daemon","diskarbitrationd","diskimages-helper","diskimagesiod","fskitd","fskit_agent"})' \
    > "$LIVE_LOG" 2>&1 &
  LOG_PID=$!
  sleep 1
fi

section "Start ephemeral-disk watcher"
(
  for _ in $(/usr/bin/seq 1 500); do
    CURRENT="$(whole_disks)"
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      if ! /usr/bin/grep -qx "$d" "$BEFORE_DISKS"; then
        printf '%s\n' "$d" > "$NEW_DISK_FILE"
        /usr/sbin/diskutil info "/dev/$d" > "$DISKINFO" 2>&1 || true
        /usr/sbin/diskutil info -plist "/dev/$d" > "$DISKINFO_PLIST" 2>/dev/null || true
        /usr/sbin/ioreg -a -r -c IOMedia > "$IOREG" 2>/dev/null || true
        /usr/bin/hdiutil info > "$HDIINFO" 2>&1 || true
        exit 0
      fi
    done <<EOF
$CURRENT
EOF
    sleep 0.01
  done
  exit 1
) &
WATCH_PID=$!

section "Run exact minfs baseline"
log "command=$MINFS_BIN -f -o backend=fskit,uid=$UID_NOW,gid=$GID_NOW $MNT"
set +e
"$MINFS_BIN" -f -o "backend=fskit,uid=$UID_NOW,gid=$GID_NOW" "$MNT" > "$MINFS_LOG" 2>&1 &
MINFS_PID=$!
for _ in $(/usr/bin/seq 1 80); do
  if [[ -r "$MNT/small.sh" ]]; then break; fi
  if ! kill -0 "$MINFS_PID" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
MINFS_PASS=0
if [[ -r "$MNT/small.sh" ]] && /bin/cat "$MNT/small.sh" >/dev/null 2>&1; then MINFS_PASS=1; fi
if kill -0 "$MINFS_PID" >/dev/null 2>&1; then
  kill "$MINFS_PID" >/dev/null 2>&1 || true
  wait "$MINFS_PID" >/dev/null 2>&1
  MINFS_RC=$?
else
  wait "$MINFS_PID" >/dev/null 2>&1
  MINFS_RC=$?
fi
set -e
MINFS_PID=""
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=""
sleep 0.4
if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo /bin/kill "$LOG_PID" >/dev/null 2>&1 || true; fi
LOG_PID=""

NEW_DISK="$(/usr/bin/head -n 1 "$NEW_DISK_FILE" 2>/dev/null || true)"
DISKINFO_CAPTURED=0
[[ -s "$DISKINFO" ]] && DISKINFO_CAPTURED=1

section "Ephemeral disk metadata"
log "new_disk=${NEW_DISK:-not-captured}"
if [[ -s "$DISKINFO" ]]; then /usr/bin/cat "$DISKINFO" | tee -a "$REPORT"; fi

section "macFUSE / FSKit critical lifecycle"
/usr/bin/grep -i -E 'Channel created|Connection to file system extension established|activateVolume|Activate virtual device|Activated device|initializ|Deactivating virtual device|Detach virtual device|Failed to mount volume|MountError|DiskImage.Error|mount\(8\)|Failed to call mount|Failed to activate' "$LIVE_LOG" | /usr/bin/tail -n 350 | tee -a "$REPORT" || true

section "Disk Arbitration lifecycle for new disk"
if [[ -n "$NEW_DISK" ]]; then
  /usr/bin/grep -F "/dev/$NEW_DISK" "$LIVE_LOG" | /usr/bin/tail -n 350 | tee -a "$REPORT" || true
fi

section "minfs log"
/usr/bin/cat "$MINFS_LOG" | tee -a "$REPORT" || true

CHANNEL_CREATED=0
EXT_ESTABLISHED=0
ACTIVATE_OK=0
VIRTUAL_ACTIVATED=0
VIRTUAL_DEACTIVATED=0
MOUNT_ERROR4=0
DISKIMAGE_ERROR=0
DA_CLAIMED=0
FSKIT_ADDITIONS=0
MOUNT8_ERROR=0
ROOT_FUSE_REQUESTS=0

/usr/bin/grep -q 'Channel created' "$LIVE_LOG" && CHANNEL_CREATED=1 || true
/usr/bin/grep -q 'Connection to file system extension established' "$LIVE_LOG" && EXT_ESTABLISHED=1 || true
/usr/bin/grep -E -q 'activateVolume.*error:0|activate volume.*error:0' "$LIVE_LOG" && ACTIVATE_OK=1 || true
/usr/bin/grep -q 'Activated device' "$LIVE_LOG" && VIRTUAL_ACTIVATED=1 || true
/usr/bin/grep -q 'Deactivating virtual device' "$LIVE_LOG" && VIRTUAL_DEACTIVATED=1 || true
/usr/bin/grep -q 'MFDaemon.MountError Code=4' "$LIVE_LOG" && MOUNT_ERROR4=1 || true
/usr/bin/grep -q 'MFDaemon.DiskImage.Error' "$LIVE_LOG" && DISKIMAGE_ERROR=1 || true
if [[ -n "$NEW_DISK" ]]; then
  /usr/bin/grep -F "/dev/$NEW_DISK" "$LIVE_LOG" | /usr/bin/grep -q 'claimed disk.*success' && DA_CLAIMED=1 || true
  /usr/bin/grep -F "/dev/$NEW_DISK" "$LIVE_LOG" | /usr/bin/grep -q 'disk fskit additions changed' && FSKIT_ADDITIONS=1 || true
fi
/usr/bin/grep -E -q 'mount\(8\).*returned|Failed to call mount\(8\)|Failed to mount volume: mount\(8\)' "$LIVE_LOG" && MOUNT8_ERROR=1 || true
/usr/bin/grep -E -q 'STATFS /|GETATTR /' "$MINFS_LOG" && ROOT_FUSE_REQUESTS=1 || true

section "SUMMARY"
log "minfs_pass=$MINFS_PASS minfs_rc=$MINFS_RC"
log "new_disk=${NEW_DISK:-none} diskinfo_captured=$DISKINFO_CAPTURED"
log "channel_created=$CHANNEL_CREATED extension_established=$EXT_ESTABLISHED activate_ok=$ACTIVATE_OK"
log "virtual_device_activated=$VIRTUAL_ACTIVATED da_claimed=$DA_CLAIMED fskit_additions=$FSKIT_ADDITIONS root_fuse_requests=$ROOT_FUSE_REQUESTS"
log "virtual_device_deactivated=$VIRTUAL_DEACTIVATED mount_error4=$MOUNT_ERROR4 diskimage_error=$DISKIMAGE_ERROR mount8_error=$MOUNT8_ERROR"

if [[ "$MINFS_PASS" -eq 1 ]]; then
  log "RESULT=MFMount_LOCAL_BASELINE_PASS"
  log "Interpretation: the local FSKit mount path succeeded during this capture. Compare this run with the prior failing state before changing EDP."
elif [[ "$CHANNEL_CREATED" -eq 1 && "$EXT_ESTABLISHED" -eq 1 && "$ACTIVATE_OK" -eq 1 && "$VIRTUAL_ACTIVATED" -eq 1 && "$ROOT_FUSE_REQUESTS" -eq 1 && "$MOUNT_ERROR4" -eq 1 ]]; then
  log "RESULT=MFMOUNT_LOCAL_FINALIZATION_FAILURE"
  log "Interpretation: channel setup, FSKit activateVolume, virtual-device activation and initial FUSE requests all succeeded. MFMount then failed while finalizing the local virtual volume and rolled it back. The failure is later than channel establishment and earlier than a reported mount(8) failure."
elif [[ "$MOUNT_ERROR4" -eq 1 && "$VIRTUAL_ACTIVATED" -eq 1 ]]; then
  log "RESULT=MFMOUNT_LOCAL_VIRTUAL_VOLUME_INIT_FAILURE"
  log "Interpretation: the virtual device was created and activated, but MFMount returned activatingDeviceFailed during the local virtual-volume initialization/finalization path."
else
  log "RESULT=MFMOUNT_LOCAL_FAILURE_OTHER"
  log "Interpretation: inspect the critical lifecycle and ephemeral disk metadata above for the earliest failed operation."
fi
log "REPORT=$REPORT"

exit 0
