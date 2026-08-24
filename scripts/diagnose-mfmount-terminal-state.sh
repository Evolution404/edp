#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-mfmount-terminal-state"
REPORT="$BASE/report.txt"
LIVE_LOG="$BASE/live.log"
BEFORE_DISKS="$BASE/before-disks.txt"
AFTER_DISKS="$BASE/after-disks.txt"
BEFORE_HDI="$BASE/hdi-before.txt"
AFTER_HDI="$BASE/hdi-after.txt"
NEW_DISK_FILE="$BASE/new-disk.txt"
DISKINFO="$BASE/new-disk-info.txt"
ISSUE_JSON="$BASE/issue-1181.json"
MINFS_C="$BASE/minfs.c"
MINFS_BIN="$BASE/minfs"
MINFS_LOG="$BASE/minfs.log"
MNT="/Volumes/edp-mfmount-terminal"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
LOG_PID=""
WATCH_PID=""
MINFS_PID=""

mkdir -p "$BASE"
: > "$REPORT"
: > "$LIVE_LOG"
: > "$NEW_DISK_FILE"
: > "$DISKINFO"
: > "$MINFS_LOG"

log(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
section(){ log ""; log "=== $* ==="; }

whole_disks(){
  /bin/ls /dev/disk* 2>/dev/null | /usr/bin/grep -E '^/dev/disk[0-9]+$' | /usr/bin/sed 's#^/dev/##' | /usr/bin/sort -V
}

cleanup_mount(){
  if /sbin/mount | /usr/bin/grep -F " on $MNT " >/dev/null 2>&1; then
    /sbin/umount "$MNT" >/dev/null 2>&1 || sudo /sbin/umount "$MNT" >/dev/null 2>&1 || true
  fi
  sudo /bin/rm -rf "$MNT" >/dev/null 2>&1 || true
}

cleanup(){
  if [[ -n "$MINFS_PID" ]] && kill -0 "$MINFS_PID" >/dev/null 2>&1; then
    kill "$MINFS_PID" >/dev/null 2>&1 || true
    sleep 0.5
    kill -9 "$MINFS_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WATCH_PID" ]] && kill -0 "$WATCH_PID" >/dev/null 2>&1; then kill "$WATCH_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo /bin/kill "$LOG_PID" >/dev/null 2>&1 || true; fi
  cleanup_mount
}
trap cleanup EXIT INT TERM

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true
log "uid=$UID_NOW gid=$GID_NOW user=$(id -un)"

section "Disk state before test"
whole_disks > "$BEFORE_DISKS"
/bin/cat "$BEFORE_DISKS" | tee -a "$REPORT"
/usr/bin/hdiutil info > "$BEFORE_HDI" 2>&1 || true
/usr/bin/grep -E '^/dev/disk|image-path|image-alias|system-entities|dev-entry' "$BEFORE_HDI" | /usr/bin/tail -n 200 | tee -a "$REPORT" || true

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
sudo -v

section "Start focused live log"
sudo /usr/bin/log stream --style compact --level debug --source \
  --predicate '(subsystem IN {"io.macfuse","com.apple.FSKit","com.apple.DiskArbitration","com.apple.DiskImages2","com.apple.diskimages"}) OR (process IN {"io.macfuse.app.launchservice.daemon","diskarbitrationd","diskimages-helper","diskimagesiod","fskitd","fskit_agent"})' \
  > "$LIVE_LOG" 2>&1 &
LOG_PID=$!
sleep 1

section "Start ephemeral-disk watcher"
(
  for _ in $(/usr/bin/seq 1 3500); do
    CURRENT="$(whole_disks)"
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      if ! /usr/bin/grep -qx "$d" "$BEFORE_DISKS"; then
        printf '%s\n' "$d" > "$NEW_DISK_FILE"
        /usr/sbin/diskutil info "/dev/$d" > "$DISKINFO" 2>&1 &
        DP=$!
        for _di in $(/usr/bin/seq 1 40); do
          kill -0 "$DP" >/dev/null 2>&1 || break
          sleep 0.05
        done
        if kill -0 "$DP" >/dev/null 2>&1; then kill "$DP" >/dev/null 2>&1 || true; fi
        wait "$DP" >/dev/null 2>&1 || true
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

section "Run exact minfs and wait for terminal state"
log "command=$MINFS_BIN -f -o backend=fskit,uid=$UID_NOW,gid=$GID_NOW $MNT"
set +e
"$MINFS_BIN" -f -o "backend=fskit,uid=$UID_NOW,gid=$GID_NOW" "$MNT" > "$MINFS_LOG" 2>&1 &
MINFS_PID=$!
log "minfs_pid=$MINFS_PID max_wait_s=35"

TERMINAL="timeout"
MOUNT_SEEN=0
for _ in $(/usr/bin/seq 1 350); do
  if /sbin/mount | /usr/bin/grep -F " on $MNT " >/dev/null 2>&1; then
    MOUNT_SEEN=1
    TERMINAL="mounted"
    break
  fi
  if /usr/bin/grep -q 'MFDaemon.MountError' "$LIVE_LOG" 2>/dev/null; then
    TERMINAL="mount_error"
    break
  fi
  if /usr/bin/grep -q 'Failed to mount volume' "$LIVE_LOG" 2>/dev/null; then
    TERMINAL="mount_error"
    break
  fi
  if ! kill -0 "$MINFS_PID" >/dev/null 2>&1; then
    TERMINAL="minfs_exited"
    break
  fi
  sleep 0.1
done
log "terminal_state=$TERMINAL"

if [[ "$TERMINAL" == "mounted" ]]; then
  sleep 1
elif [[ "$TERMINAL" == "mount_error" ]]; then
  sleep 1
elif [[ "$TERMINAL" == "minfs_exited" ]]; then
  sleep 0.5
else
  log "no_terminal_event_within_35s=1"
fi

if kill -0 "$MINFS_PID" >/dev/null 2>&1; then
  kill "$MINFS_PID" >/dev/null 2>&1 || true
  for _ in $(/usr/bin/seq 1 30); do
    kill -0 "$MINFS_PID" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if kill -0 "$MINFS_PID" >/dev/null 2>&1; then kill -9 "$MINFS_PID" >/dev/null 2>&1 || true; fi
fi
wait "$MINFS_PID" >/dev/null 2>&1
MINFS_RC=$?
MINFS_PID=""

sleep 1.5
if [[ -n "$WATCH_PID" ]] && kill -0 "$WATCH_PID" >/dev/null 2>&1; then kill "$WATCH_PID" >/dev/null 2>&1 || true; fi
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=""
if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo /bin/kill "$LOG_PID" >/dev/null 2>&1 || true; fi
LOG_PID=""
set -e

whole_disks > "$AFTER_DISKS"
/usr/bin/hdiutil info > "$AFTER_HDI" 2>&1 || true
NEW_DISK="$(/usr/bin/head -n 1 "$NEW_DISK_FILE" 2>/dev/null || true)"

section "Ephemeral disk metadata"
log "new_disk=${NEW_DISK:-not-captured}"
if [[ -s "$DISKINFO" ]]; then /bin/cat "$DISKINFO" | tee -a "$REPORT"; fi

section "Critical lifecycle"
/usr/bin/grep -i -E 'Advertise server|Activate virtual device|Activated device|Channel created|Connection to file system extension established|loadResource|activateVolume|error:0|Deactivating virtual device|Detach virtual device|Failed to mount volume|MountError|DiskImage.Error|Connection to file system server invalidated|Connection to file system extension invalidated' "$LIVE_LOG" | /usr/bin/tail -n 500 | tee -a "$REPORT" || true

section "Disk Arbitration lifecycle for new disk"
if [[ -n "$NEW_DISK" ]]; then
  /usr/bin/grep -F "/dev/$NEW_DISK" "$LIVE_LOG" | /usr/bin/tail -n 500 | tee -a "$REPORT" || true
fi

section "Disk state after test"
/bin/cat "$AFTER_DISKS" | tee -a "$REPORT"
log "new_whole_disks_remaining_after_test:"
/usr/bin/comm -13 "$BEFORE_DISKS" "$AFTER_DISKS" | tee -a "$REPORT" || true
/usr/bin/grep -E '^/dev/disk|image-path|image-alias|system-entities|dev-entry' "$AFTER_HDI" | /usr/bin/tail -n 200 | tee -a "$REPORT" || true

section "minfs log"
/bin/cat "$MINFS_LOG" | tee -a "$REPORT" || true

CHANNEL_CREATED=0
EXT_ESTABLISHED=0
ACTIVATE_OK=0
VIRTUAL_ACTIVATED=0
VIRTUAL_DEACTIVATED=0
MOUNT_ERROR4=0
DISKIMAGE_ERROR=0
DA_CLAIMED=0
FSKIT_ADDITIONS=0
ROOT_FUSE_REQUESTS=0
LEFTOVER_NEW_DISKS=0

/usr/bin/grep -q 'Channel created' "$LIVE_LOG" && CHANNEL_CREATED=1 || true
/usr/bin/grep -q 'Connection to file system extension established' "$LIVE_LOG" && EXT_ESTABLISHED=1 || true
/usr/bin/grep -E -q 'activateVolume.*error:0|activate volume.*error:0|error:0:rootItem' "$LIVE_LOG" && ACTIVATE_OK=1 || true
/usr/bin/grep -q 'Activated device' "$LIVE_LOG" && VIRTUAL_ACTIVATED=1 || true
/usr/bin/grep -q 'Deactivating virtual device' "$LIVE_LOG" && VIRTUAL_DEACTIVATED=1 || true
/usr/bin/grep -q 'MFDaemon.MountError Code=4' "$LIVE_LOG" && MOUNT_ERROR4=1 || true
/usr/bin/grep -q 'MFDaemon.DiskImage.Error' "$LIVE_LOG" && DISKIMAGE_ERROR=1 || true
if [[ -n "$NEW_DISK" ]]; then
  /usr/bin/grep -F "/dev/$NEW_DISK" "$LIVE_LOG" | /usr/bin/grep -q 'claimed disk.*success' && DA_CLAIMED=1 || true
  /usr/bin/grep -F "/dev/$NEW_DISK" "$LIVE_LOG" | /usr/bin/grep -q 'disk fskit additions changed' && FSKIT_ADDITIONS=1 || true
fi
/usr/bin/grep -E -q 'STATFS /|GETATTR /' "$MINFS_LOG" && ROOT_FUSE_REQUESTS=1 || true
LEFTOVER_NEW_DISKS="$(/usr/bin/comm -13 "$BEFORE_DISKS" "$AFTER_DISKS" | /usr/bin/grep -c '^disk' || true)"

section "SUMMARY"
log "terminal_state=$TERMINAL mount_seen=$MOUNT_SEEN minfs_rc=$MINFS_RC"
log "new_disk=${NEW_DISK:-none} leftover_new_disks=$LEFTOVER_NEW_DISKS"
log "channel_created=$CHANNEL_CREATED extension_established=$EXT_ESTABLISHED activate_ok=$ACTIVATE_OK"
log "virtual_device_activated=$VIRTUAL_ACTIVATED da_claimed=$DA_CLAIMED fskit_additions=$FSKIT_ADDITIONS root_fuse_requests=$ROOT_FUSE_REQUESTS"
log "virtual_device_deactivated=$VIRTUAL_DEACTIVATED mount_error4=$MOUNT_ERROR4 diskimage_error=$DISKIMAGE_ERROR"

if [[ "$MOUNT_SEEN" -eq 1 ]]; then
  log "RESULT=MFMOUNT_LOCAL_MOUNT_OBSERVED"
elif [[ "$MOUNT_ERROR4" -eq 1 && "$VIRTUAL_ACTIVATED" -eq 1 && "$CHANNEL_CREATED" -eq 1 && "$ACTIVATE_OK" -eq 1 ]]; then
  log "RESULT=MFMOUNT_LOCAL_POST_ACTIVATION_FAILURE_CONFIRMED"
elif [[ "$MOUNT_ERROR4" -eq 1 && "$VIRTUAL_ACTIVATED" -eq 1 ]]; then
  log "RESULT=MFMOUNT_LOCAL_VIRTUAL_DEVICE_FINALIZATION_FAILURE"
elif [[ "$TERMINAL" == "timeout" && "$VIRTUAL_ACTIVATED" -eq 0 ]]; then
  log "RESULT=VIRTUAL_DEVICE_ACTIVATION_STALLED"
elif [[ "$LEFTOVER_NEW_DISKS" -gt 0 ]]; then
  log "RESULT=TEST_LEFT_VIRTUAL_DISK_ATTACHED"
else
  log "RESULT=MFMOUNT_TERMINAL_STATE_OTHER"
fi
log "REPORT=$REPORT"

exit 0
