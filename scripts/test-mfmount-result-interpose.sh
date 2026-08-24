#!/bin/bash
set -u
set -o pipefail

WORK="${TMPDIR:-/tmp}/edp-mfmount-result-interpose"
DEMO="$WORK/demo"
SRC="$DEMO/LoopbackFS/LoopbackFS-libfuse3-C/main.c"
ENT="$DEMO/LoopbackFS/LoopbackFS-libfuse3-C/LoopbackFS.entitlements"
BIN="$WORK/LoopbackFS3"
INTERPOSE_SRC="$WORK/mfmount_interpose.c"
INTERPOSE_DYLIB="$WORK/libmfmount_interpose.dylib"
SOURCE_DIR="$WORK/source"
MOUNT_POINT="/Volumes/edp-mfmount-result"
SERVER_LOG="$WORK/server.log"
SYSTEM_LOG="$WORK/system.log"
REPORT="$WORK/report.txt"
PID=""
LOGPID=""

mkdir -p "$WORK"
: > "$REPORT"
: > "$SERVER_LOG"
: > "$SYSTEM_LOG"

log() { printf '%s\n' "$*" | /usr/bin/tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

watch_exec() {
  local seconds="$1"
  shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

count_images() {
  local out
  out="$(watch_exec 10 /usr/bin/hdiutil info 2>/dev/null | /usr/bin/grep -c '^image-path' || true)"
  if [[ "$out" =~ ^[0-9]+$ ]]; then
    printf '%s' "$out"
  else
    printf 'unknown'
  fi
}

cleanup() {
  if [[ -n "$LOGPID" ]] && /bin/kill -0 "$LOGPID" >/dev/null 2>&1; then
    /bin/kill "$LOGPID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PID" ]] && /bin/kill -0 "$PID" >/dev/null 2>&1; then
    /bin/kill "$PID" >/dev/null 2>&1 || true
  fi
  if /sbin/mount | /usr/bin/grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
    watch_exec 5 /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

section "System"
/usr/bin/sw_vers 2>&1 | /usr/bin/tee -a "$REPORT"
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "Clean-state gate"
IMAGES_BEFORE="$(count_images)"
log "hdiutil_images_before=$IMAGES_BEFORE"
if [[ "$IMAGES_BEFORE" != "0" ]]; then
  log "RESULT=ABORT_NOT_CLEAN"
  log "Interpretation: this test performs exactly one FSKit mount attempt and refuses to run while any hdiutil disk image is attached."
  exit 4
fi

section "Verify MFMount symbol"
MFMOUNT_BIN="/Library/Frameworks/MFMount.framework/MFMount"
if [[ ! -f "$MFMOUNT_BIN" ]]; then
  log "mfmount_framework=missing"
  log "RESULT=MFMOUNT_FRAMEWORK_MISSING"
  exit 2
fi
if /usr/bin/nm -gU "$MFMOUNT_BIN" 2>/dev/null | /usr/bin/grep -Eq '[[:space:]]_MFMount$'; then
  log "mfmount_symbol=present"
else
  log "mfmount_symbol=not-confirmed"
  log "RESULT=MFMOUNT_SYMBOL_NOT_FOUND"
  exit 2
fi

section "Build MFMount return-value interposer"
/bin/cat > "$INTERPOSE_SRC" <<'C'
#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef void *MFChannelRef;
typedef int32_t MFMountResult;
typedef MFMountResult (*MFMountFn)(MFChannelRef, const char *, const char *, bool);

MFMountResult MFMount(MFChannelRef channel, const char *mountPoint, const char *options, bool quiet)
{
    static MFMountFn realMFMount = NULL;
    if (realMFMount == NULL) {
        realMFMount = (MFMountFn)dlsym(RTLD_NEXT, "MFMount");
        if (realMFMount == NULL) {
            fprintf(stderr, "EDP_MFMOUNT_TRACE phase=resolve result=-999 errno=%d dlerror=%s\n",
                    errno, dlerror() ? dlerror() : "unknown");
            fflush(stderr);
            errno = EAGAIN;
            return -1;
        }
    }

    fprintf(stderr, "EDP_MFMOUNT_TRACE phase=enter quiet=%d mountpoint=%s\n",
            quiet ? 1 : 0, mountPoint ? mountPoint : "(null)");
    fflush(stderr);

    errno = 0;
    MFMountResult result = realMFMount(channel, mountPoint, options, quiet);
    int saved_errno = errno;

    fprintf(stderr, "EDP_MFMOUNT_TRACE phase=return result=%d errno=%d\n",
            (int)result, saved_errno);
    fflush(stderr);

    errno = saved_errno;
    return result;
}
C

if ! /usr/bin/cc -dynamiclib -O0 -Wall -Wextra "$INTERPOSE_SRC" -o "$INTERPOSE_DYLIB" -ldl >>"$REPORT" 2>&1; then
  log "RESULT=INTERPOSER_BUILD_FAILED"
  exit 2
fi
/usr/bin/codesign --force --sign - "$INTERPOSE_DYLIB" >>"$REPORT" 2>&1 || true
log "interposer_build=ok"

section "Fetch and build official LoopbackFS-libfuse3-C"
/bin/rm -rf "$DEMO"
if ! /usr/bin/git clone --depth 1 https://github.com/macfuse/demo.git "$DEMO" >>"$REPORT" 2>&1; then
  log "RESULT=FETCH_FAILED"
  exit 2
fi
if [[ ! -f "$SRC" || ! -f "$ENT" ]]; then
  log "RESULT=DEMO_LAYOUT_CHANGED"
  exit 2
fi
if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists fuse3; then
  log "RESULT=LIBFUSE3_NOT_FOUND"
  exit 2
fi
log "fuse_version=$(pkg-config --modversion fuse3)"
if ! /usr/bin/cc "$SRC" -D_FILE_OFFSET_BITS=64 $(pkg-config --cflags fuse3) $(pkg-config --libs fuse3) -o "$BIN" >>"$REPORT" 2>&1; then
  log "RESULT=BUILD_FAILED"
  exit 2
fi
/usr/bin/codesign --force --sign - --entitlements "$ENT" "$BIN" >>"$REPORT" 2>&1 || true
log "loopback_build=ok"

section "Prepare mount point"
/bin/rm -rf "$SOURCE_DIR"
/bin/mkdir -p "$SOURCE_DIR"
printf 'mfmount-result-probe\n' > "$SOURCE_DIR/probe.txt"
/usr/bin/sudo -v
/usr/bin/sudo /bin/rm -rf "$MOUNT_POINT"
/usr/bin/sudo /bin/mkdir "$MOUNT_POINT"
/usr/bin/sudo /usr/sbin/chown "$(id -u):$(id -g)" "$MOUNT_POINT"
/bin/chmod 700 "$MOUNT_POINT"

section "Capture unified log"
/usr/bin/log stream --style compact --level debug \
  --predicate 'subsystem == "io.macfuse" OR subsystem == "com.apple.FSKit" OR subsystem == "com.apple.DiskArbitration.diskarbitrationd"' \
  >"$SYSTEM_LOG" 2>&1 &
LOGPID=$!

section "Exactly one instrumented mount attempt"
log "dyld_interpose=$INTERPOSE_DYLIB"
(
  cd "$SOURCE_DIR" || exit 90
  exec /usr/bin/env DYLD_INSERT_LIBRARIES="$INTERPOSE_DYLIB" "$BIN" -f -s \
    -o "backend=fskit,modules=subdir,subdir=$SOURCE_DIR,uid=$(id -u),gid=$(id -g),volname=EDPMFMountResult" \
    "$MOUNT_POINT"
) >"$SERVER_LOG" 2>&1 &
PID=$!
log "server_pid=$PID"

MOUNT_SEEN=0
for i in $(/usr/bin/seq 1 20); do
  if /sbin/mount | /usr/bin/grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
    MOUNT_SEEN=1
    log "mount_seen_after=${i}s"
    break
  fi
  if ! /bin/kill -0 "$PID" >/dev/null 2>&1; then
    log "server_exited_after=${i}s"
    break
  fi
  /bin/sleep 1
done

/bin/sleep 2

section "MFMount trace"
TRACE_ENTER="$(/usr/bin/grep 'EDP_MFMOUNT_TRACE phase=enter' "$SERVER_LOG" | /usr/bin/tail -n 1 || true)"
TRACE_RETURN="$(/usr/bin/grep 'EDP_MFMOUNT_TRACE phase=return' "$SERVER_LOG" | /usr/bin/tail -n 1 || true)"
TRACE_RESOLVE="$(/usr/bin/grep 'EDP_MFMOUNT_TRACE phase=resolve' "$SERVER_LOG" | /usr/bin/tail -n 1 || true)"
log "trace_enter=${TRACE_ENTER:-missing}"
log "trace_return=${TRACE_RETURN:-missing}"
log "trace_resolve=${TRACE_RESOLVE:-none}"

MFMOUNT_RESULT="$(printf '%s\n' "$TRACE_RETURN" | /usr/bin/sed -n 's/.*result=\(-\{0,1\}[0-9][0-9]*\).*/\1/p')"
MFMOUNT_ERRNO="$(printf '%s\n' "$TRACE_RETURN" | /usr/bin/sed -n 's/.*errno=\([0-9][0-9]*\).*/\1/p')"
log "mfmount_result=${MFMOUNT_RESULT:-unknown}"
log "mfmount_errno=${MFMOUNT_ERRNO:-unknown}"

section "Daemon outcome"
MERR="$(/usr/bin/grep -o 'MFDaemon.MountError Code=[0-9]*' "$SYSTEM_LOG" | /usr/bin/tail -n 1 || true)"
DERR="$(/usr/bin/grep -o 'MFDaemon.DiskImage.Error Code=[0-9]*' "$SYSTEM_LOG" | /usr/bin/tail -n 1 || true)"
ACTIVATED="$(/usr/bin/grep -c 'Activated device' "$SYSTEM_LOG" || true)"
ACTIVATE_VOLUME_OK="$(/usr/bin/grep -c 'activateVolume:resource:options:replyHandler:.*error:0' "$SYSTEM_LOG" || true)"
log "mount_seen=$MOUNT_SEEN"
log "virtual_device_activated=$ACTIVATED"
log "activate_volume_error0=$ACTIVATE_VOLUME_OK"
log "daemon_mount_error=${MERR:-none}"
log "daemon_detach_error=${DERR:-none}"

IMAGES_AFTER="$(count_images)"
log "hdiutil_images_after=$IMAGES_AFTER"

section "Classification"
case "${MFMOUNT_RESULT:-unknown}" in
  0)
    log "PUBLIC_RESULT=SUCCESS"
    ;;
  1)
    log "PUBLIC_RESULT=UNSUPPORTED_OS_VERSION"
    ;;
  2)
    log "PUBLIC_RESULT=HELPER_TOOLS_INSTALLATION_FAILED"
    ;;
  3)
    log "PUBLIC_RESULT=FILE_SYSTEM_EXTENSION_NOT_FOUND"
    ;;
  4)
    log "PUBLIC_RESULT=FILE_SYSTEM_EXTENSION_REQUIRES_APPROVAL"
    ;;
  -1)
    log "PUBLIC_RESULT=UNEXPECTED_FAILURE"
    ;;
  *)
    log "PUBLIC_RESULT=UNKNOWN_OR_TRACE_MISSING"
    ;;
esac

if [[ "$IMAGES_AFTER" != "0" ]]; then
  log "RESULT=TRACE_COMPLETE_BUT_ORPHAN_CREATED"
elif [[ -z "${MFMOUNT_RESULT:-}" ]]; then
  log "RESULT=TRACE_INCONCLUSIVE"
else
  log "RESULT=TRACE_COMPLETE"
fi

log "REPORT=$REPORT"
log "SERVER_LOG=$SERVER_LOG"
log "SYSTEM_LOG=$SYSTEM_LOG"
exit 0
