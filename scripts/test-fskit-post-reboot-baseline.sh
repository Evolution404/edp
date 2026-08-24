#!/bin/bash
# Post-reboot single-shot macFUSE FSKit baseline.
#
# Purpose: after a clean reboot (orphan diskimages gone, diskarbitrationd fresh),
# run exactly ONE official-baseline mount attempt and classify the outcome with
# the error-code semantics extracted from the MFDaemon 5.3.3 binary:
#   MFDaemon.MountError Code=4 = fileSystemExtensionRequiresApproval
#   MFDaemon.Broker.Error  Code=1 = timeout (10s advertise deadline)
#   MFDaemon.DiskImage.Error Code=2 = detachFailed
#
# Rules honored (see repo history):
#   - No GNU timeout; perl alarm watchdogs for anything that can block.
#   - Success is judged ONLY from the mount table, never by stat()ing files
#     inside the possibly-broken FSKit mountpoint.
#   - trap EXIT INT TERM; no run may leave a foreground hang behind.
#   - Single mount attempt: failure may still leave at most one 4KB orphan
#     image if macFUSE's rollback fails again (its bug); we count and report it.

set -u
set -o pipefail

# All sudo calls go through -A + SUDO_ASKPASS so the script works without a
# terminal (caller must export SUDO_ASKPASS pointing at an executable that
# echoes the password; a normal interactive run without SUDO_ASKPASS degrades
# gracefully because sudo -A falls back to the normal prompt path).
SUDO="sudo"

WORK="${TMPDIR:-/tmp}/edp-fskit-postreboot"
DEMO="$WORK/demo"
SRC="$DEMO/LoopbackFS/LoopbackFS-libfuse3-C/main.c"
ENT="$DEMO/LoopbackFS/LoopbackFS-libfuse3-C/LoopbackFS.entitlements"
BIN="$WORK/LoopbackFS3"
SOURCE_DIR="$WORK/source"
MOUNT_POINT="/Volumes/edp-fskit-baseline"
SERVER_LOG="$WORK/server.log"
SYSTEM_LOG="$WORK/system.log"
REPORT="${TMPDIR:-/tmp}/edp-fskit-postreboot-report.txt"
PID=""
LOGPID=""

mkdir -p "$WORK"
: > "$REPORT"
: > "$SERVER_LOG"
: > "$SYSTEM_LOG"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

cleanup() {
  if [[ -n "$LOGPID" ]] && kill -0 "$LOGPID" >/dev/null 2>&1; then
    kill "$LOGPID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
  fi
  # Only umount if the mount table actually shows a successful mount, and
  # only with a watchdog: a broken FSKit mountpoint can hang umount too.
  if /sbin/mount | /usr/bin/grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
    /usr/bin/perl -e 'alarm shift; exec @ARGV' 5 /sbin/umount "$MOUNT_POINT" \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

count_images() {
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 10 /usr/bin/hdiutil info 2>/dev/null \
    | /usr/bin/grep -c '^image-path' || echo '?'
}

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "Pre-flight cleanliness"
IMAGES_BEFORE=$(count_images)
log "hdiutil_images_before=$IMAGES_BEFORE"
/usr/bin/pluginkit -mAvvv 2>/dev/null | /usr/bin/grep -B1 -A3 'io.macfuse.app.fsmodule.macfuse-local' \
  | tee -a "$REPORT" || log "pluginkit_record=MISSING"

section "Fetch and build official LoopbackFS-libfuse3-C"
/bin/rm -rf "$DEMO"
if ! /usr/bin/git clone --depth 1 https://github.com/macfuse/demo.git "$DEMO" >>"$REPORT" 2>&1; then
  log "RESULT=FETCH_FAILED"
  exit 2
fi
if [[ ! -f "$SRC" ]]; then
  log "RESULT=DEMO_LAYOUT_CHANGED"
  exit 2
fi
if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists fuse3; then
  log "RESULT=LIBFUSE3_NOT_FOUND"
  exit 2
fi
log "fuse_version=$(pkg-config --modversion fuse3)"
set +e
/usr/bin/cc "$SRC" -D_FILE_OFFSET_BITS=64 $(pkg-config --cflags fuse3) $(pkg-config --libs fuse3) \
  -o "$BIN" >>"$REPORT" 2>&1
BUILD_RC=$?
set -e
[[ "$BUILD_RC" -ne 0 ]] && { log "RESULT=BUILD_FAILED"; exit 2; }
/usr/bin/codesign --force --sign - --entitlements "$ENT" "$BIN" >>"$REPORT" 2>&1 || true

section "Prepare mount point"
/bin/rm -rf "$SOURCE_DIR"
/bin/mkdir -p "$SOURCE_DIR"
printf 'fskit-baseline-ok\n' > "$SOURCE_DIR/probe.txt"
if [[ -n "${SUDO_ASKPASS:-}" && -x "${SUDO_ASKPASS:-}" ]]; then
  SUDO="sudo -A"
fi
$SUDO -v
$SUDO /bin/rm -rf "$MOUNT_POINT"
$SUDO /bin/mkdir "$MOUNT_POINT"
$SUDO /usr/sbin/chown "$(id -u):$(id -g)" "$MOUNT_POINT"
/bin/chmod 700 "$MOUNT_POINT"

section "Capture unified log (background, killed on exit)"
/usr/bin/log stream --style compact --level debug \
  --predicate 'subsystem == "io.macfuse" OR subsystem == "com.apple.FSKit" OR subsystem == "com.apple.DiskArbitration.diskarbitrationd"' \
  >"$SYSTEM_LOG" 2>&1 &
LOGPID=$!

section "Single mount attempt"
log "cmd: LoopbackFS3 -f -s -o backend=fskit,modules=subdir,subdir=$SOURCE_DIR,uid=$(id -u),gid=$(id -g),volname=EDPFskitBaseline $MOUNT_POINT"
(
  cd "$SOURCE_DIR" || exit 90
  exec "$BIN" -f -s -o "backend=fskit,modules=subdir,subdir=$SOURCE_DIR,uid=$(id -u),gid=$(id -g),volname=EDPFskitBaseline" "$MOUNT_POINT"
) >"$SERVER_LOG" 2>&1 &
PID=$!
log "server_pid=$PID"

MOUNT_SEEN=0
# 60s watchdog: virtual device creation alone took >6s cold; allow ample time.
for i in $(seq 1 60); do
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    log "server_exited_after=${i}s"
    break
  fi
  if /sbin/mount | /usr/bin/grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
    MOUNT_SEEN=1
    log "mount_seen_after=${i}s"
    break
  fi
  sleep 1
done

section "Outcome"
IMAGES_AFTER=$(count_images)
log "mount_seen=$MOUNT_SEEN"
log "hdiutil_images_after=$IMAGES_AFTER"

if [[ "$MOUNT_SEEN" -eq 1 ]]; then
  # Mount table confirms success; reading inside is now safe.
  CONTENT="$(/bin/cat "$MOUNT_POINT/probe.txt" 2>/dev/null || true)"
  log "probe_content=$CONTENT"
  log "RESULT=BASELINE_OK"
else
  sleep 2   # let daemon-side error lines land in the log
  MERR=$(/usr/bin/grep -o 'MFDaemon.MountError Code=[0-9]*' "$SYSTEM_LOG" | tail -1 || true)
  BERR=$(/usr/bin/grep -o 'Broker<[^>]*>*\.Error Code=[0-9]*' "$SYSTEM_LOG" | tail -1 || true)
  DERR=$(/usr/bin/grep -o 'MFDaemon.DiskImage.Error Code=[0-9]*' "$SYSTEM_LOG" | tail -1 || true)
  log "mount_error=${MERR:-none}"
  log "broker_error=${BERR:-none}"
  log "detach_error=${DERR:-none}"
  if [[ -n "$MERR" && "$MERR" = *'Code=4' ]]; then
    log "VERDICT=fileSystemExtensionRequiresApproval (FSKit authorization denies the mount; macOS 15.7.7 path, not EDP)"
  elif [[ -n "$BERR" && "$BERR" = *'Code=1' ]]; then
    log "VERDICT=advertise timeout (extension never claimed the server)"
  else
    log "VERDICT=UNClassified (inspect $SYSTEM_LOG)"
  fi
  log "RESULT=BASELINE_FAILED"
fi

log "REPORT=$REPORT"
log "SYSTEM_LOG=$SYSTEM_LOG"
log "SERVER_LOG=$SERVER_LOG"
exit 0
