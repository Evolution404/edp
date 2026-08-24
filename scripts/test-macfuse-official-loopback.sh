#!/bin/bash
set -u
set -o pipefail

WORK="${TMPDIR:-/tmp}/edp-macfuse-official-loopback"
DEMO="$WORK/demo"
SRC="$DEMO/LoopbackFS/LoopbackFS-libfuse2-C/main.c"
ENT="$DEMO/LoopbackFS/LoopbackFS-libfuse2-C/LoopbackFS.entitlements"
BIN="$WORK/LoopbackFS"
SOURCE_DIR="$WORK/source"
MOUNT_POINT="/Volumes/edp-macfuse-official"
SERVER_LOG="$WORK/server.log"
SYSTEM_LOG="$WORK/system.log"
REPORT="${TMPDIR:-/tmp}/edp-macfuse-official-loopback-report.txt"
PID=""
PASS=0

mkdir -p "$WORK"
: > "$REPORT"
: > "$SERVER_LOG"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
    sleep 0.2
  fi
  if /sbin/mount | grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
    /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || sudo /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  sudo /bin/rm -rf "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/bin/uname -m 2>&1 | tee -a "$REPORT"
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "PluginKit records"
/usr/bin/pluginkit -m -A -D -i io.macfuse.app.fsmodule.macfuse 2>&1 | tee -a "$REPORT" || true
/usr/bin/pluginkit -m -A -D -i io.macfuse.app.fsmodule.macfuse-local 2>&1 | tee -a "$REPORT" || true

section "Fetch official macFUSE demo"
/bin/rm -rf "$DEMO"
if ! /usr/bin/git clone --depth 1 https://github.com/macfuse/demo.git "$DEMO" 2>&1 | tee -a "$REPORT"; then
  log "RESULT=FETCH_OFFICIAL_DEMO_FAILED"
  log "REPORT=$REPORT"
  exit 2
fi

if [[ ! -f "$SRC" || ! -f "$ENT" ]]; then
  log "RESULT=OFFICIAL_DEMO_LAYOUT_CHANGED"
  log "REPORT=$REPORT"
  exit 2
fi

section "Build official LoopbackFS-libfuse2-C"
if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists fuse; then
  log "RESULT=LIBFUSE2_NOT_FOUND"
  log "REPORT=$REPORT"
  exit 2
fi

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
log "fuse_version=$(pkg-config --modversion fuse)"
log "cflags=$FUSE_CFLAGS"
log "libs=$FUSE_LIBS"

set +e
/usr/bin/cc "$SRC" -D_FILE_OFFSET_BITS=64 $FUSE_CFLAGS $FUSE_LIBS -o "$BIN" 2>&1 | tee -a "$REPORT"
BUILD_RC=${PIPESTATUS[0]}
set -e
if [[ "$BUILD_RC" -ne 0 ]]; then
  log "RESULT=OFFICIAL_DEMO_BUILD_FAILED"
  log "REPORT=$REPORT"
  exit 2
fi

/usr/bin/otool -L "$BIN" 2>&1 | tee -a "$REPORT"

section "Ad-hoc sign with official demo entitlement"
set +e
/usr/bin/codesign --force --sign - --entitlements "$ENT" "$BIN" 2>&1 | tee -a "$REPORT"
SIGN_RC=${PIPESTATUS[0]}
set -e
log "codesign_rc=$SIGN_RC"
/usr/bin/codesign -d --entitlements :- "$BIN" 2>&1 | tee -a "$REPORT" || true

section "Prepare source and mount point"
/bin/rm -rf "$SOURCE_DIR"
/bin/mkdir -p "$SOURCE_DIR"
printf 'macFUSE official LoopbackFS FSKit OK\n' > "$SOURCE_DIR/probe.txt"

sudo -v
if /sbin/mount | grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
  sudo /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
fi
sudo /bin/rm -rf "$MOUNT_POINT"
sudo /bin/mkdir "$MOUNT_POINT"
sudo /usr/sbin/chown "$(id -u):$(id -g)" "$MOUNT_POINT"
/bin/chmod 700 "$MOUNT_POINT"

log "source=$SOURCE_DIR"
log "mountpoint=$MOUNT_POINT"

section "Run official LoopbackFS through FSKit"
log "command: (cd source && LoopbackFS -f -s -o backend=fskit,uid=$(id -u),gid=$(id -g),volname=EDPOfficialLoopback mountpoint)"
(
  cd "$SOURCE_DIR" || exit 90
  exec "$BIN" -f -s -o "backend=fskit,uid=$(id -u),gid=$(id -g),volname=EDPOfficialLoopback" "$MOUNT_POINT"
) >"$SERVER_LOG" 2>&1 &
PID=$!
log "server_pid=$PID"

for _ in $(seq 1 50); do
  if [[ -r "$MOUNT_POINT/probe.txt" ]]; then
    CONTENT="$(/bin/cat "$MOUNT_POINT/probe.txt" 2>/dev/null || true)"
    if [[ "$CONTENT" == "macFUSE official LoopbackFS FSKit OK" ]]; then
      PASS=1
      break
    fi
  fi
  sleep 0.2
done

section "Process state"
if kill -0 "$PID" >/dev/null 2>&1; then
  log "server_running=1"
else
  set +e
  wait "$PID"
  SERVER_RC=$?
  set -e
  log "server_running=0 server_rc=$SERVER_RC"
fi

section "Mount table"
/sbin/mount 2>&1 | /usr/bin/grep -i -E 'macfuse|edp-macfuse-official|EDPOfficialLoopback' | tee -a "$REPORT" || log "No matching mount entry"

section "Mounted probe"
/bin/ls -la "$MOUNT_POINT" 2>&1 | tee -a "$REPORT" || true
/bin/cat "$MOUNT_POINT/probe.txt" 2>&1 | tee -a "$REPORT" || true

section "Official LoopbackFS server log"
/bin/cat "$SERVER_LOG" 2>&1 | tee -a "$REPORT" || true

section "FSKit/macFUSE runtime log"
/usr/bin/log show --debug --info \
  --predicate '(subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"}) OR (process == "pkd")' \
  --last 3m 2>&1 | /usr/bin/tail -n 350 > "$SYSTEM_LOG"
/bin/cat "$SYSTEM_LOG" | tee -a "$REPORT"

CHANNEL_INVALIDATED=0
EXT_NOT_ENABLED=0
EXT_NOT_FOUND=0
PLUGIN_REJECTED=0
if /usr/bin/grep -E -q 'Connection to file system (server|extension) invalidated|MFDaemon\.MountError Code=4' "$SYSTEM_LOG" "$SERVER_LOG" 2>/dev/null; then CHANNEL_INVALIDATED=1; fi
if /usr/bin/grep -E -q 'File system extension not enabled' "$SYSTEM_LOG" "$SERVER_LOG" 2>/dev/null; then EXT_NOT_ENABLED=1; fi
if /usr/bin/grep -E -q 'File system extension .* not found|File system extension not found' "$SYSTEM_LOG" "$SERVER_LOG" 2>/dev/null; then EXT_NOT_FOUND=1; fi
if /usr/bin/grep -E -q 'rejecting; Ignoring mis-configured plugin' "$SYSTEM_LOG" 2>/dev/null; then PLUGIN_REJECTED=1; fi

section "SUMMARY"
log "pass=$PASS channel_invalidated=$CHANNEL_INVALIDATED extension_not_enabled=$EXT_NOT_ENABLED extension_not_found=$EXT_NOT_FOUND plugin_rejected=$PLUGIN_REJECTED"
if [[ "$PASS" -eq 1 ]]; then
  log "RESULT=OFFICIAL_LOOPBACK_PASS"
  log "Interpretation: macFUSE FSKit works with the official libfuse2 reference implementation. The earlier standalone smoke test was not authoritative; return to comparing EDP bridge behavior with official LoopbackFS."
elif [[ "$EXT_NOT_FOUND" -eq 1 ]]; then
  log "RESULT=OFFICIAL_LOOPBACK_EXTENSION_NOT_FOUND"
  log "Interpretation: PluginKit records exist but the runtime FSKit path still cannot resolve the macFUSE extension. This is macFUSE/macOS registration state, not EDP."
elif [[ "$CHANNEL_INVALIDATED" -eq 1 ]]; then
  log "RESULT=OFFICIAL_LOOPBACK_CHANNEL_INVALIDATED"
  log "Interpretation: even macFUSE's own libfuse2 reference filesystem reaches FSKit and loses the channel. This isolates the problem below EDP and below our custom smoke implementation."
elif [[ "$EXT_NOT_ENABLED" -eq 1 ]]; then
  log "RESULT=OFFICIAL_LOOPBACK_EXTENSION_NOT_ENABLED"
  log "Interpretation: macFUSE reports the extension as not enabled even though PluginKit has records; inspect user approval/FSKit state without changing EDP permissions."
else
  log "RESULT=OFFICIAL_LOOPBACK_FAIL_OTHER"
  log "Interpretation: inspect the official server and FSKit logs above for the first failing operation."
fi
log "REPORT=$REPORT"

if [[ "$PASS" -eq 1 ]]; then
  exit 0
else
  exit 1
fi
