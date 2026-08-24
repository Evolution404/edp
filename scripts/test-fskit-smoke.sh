#!/bin/bash

set -u

MOUNT_POINT="/Volumes/edp-fskit-smoke"
WORK_DIR="${TMPDIR:-/tmp}/edp-fskit-smoke"
SOURCE_FILE="$WORK_DIR/minfs.c"
BINARY_FILE="$WORK_DIR/minfs"
SERVER_LOG="$WORK_DIR/server.log"
REPORT_FILE="${TMPDIR:-/tmp}/edp-fskit-smoke-report.txt"
PID=""
PASS=0

mkdir -p "$WORK_DIR"
: > "$SERVER_LOG"
: > "$REPORT_FILE"

log() {
  printf '%s\n' "$*" | tee -a "$REPORT_FILE"
}

section() {
  log ""
  log "=== $* ==="
}

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

section "EDP macFUSE / FSKit smoke test"
log "Report: $REPORT_FILE"
log "Time: $(date '+%Y-%m-%d %H:%M:%S %z')"

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT_FILE"
/usr/bin/uname -m 2>&1 | tee -a "$REPORT_FILE"
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "macFUSE runtime"
if ! command -v pkg-config >/dev/null 2>&1; then
  log "FAIL: pkg-config not found"
  exit 2
fi

if ! pkg-config --exists fuse; then
  log "FAIL: pkg-config cannot find fuse"
  exit 2
fi

log "libfuse version: $(pkg-config --modversion fuse 2>&1)"
log "cflags: $(pkg-config --cflags fuse 2>&1)"
log "libs: $(pkg-config --libs fuse 2>&1)"

section "macFUSE FSKit extension registration"
/usr/bin/pluginkit -m -A -D 2>&1 | /usr/bin/grep -i -C 3 macfuse | tee -a "$REPORT_FILE" || log "No macFUSE entry returned by pluginkit"

cat > "$SOURCE_FILE" <<'EOF'
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#ifndef ENOATTR
#ifdef ENODATA
#define ENOATTR ENODATA
#else
#define ENOATTR ENOENT
#endif
#endif

static const char content[] = "EDP FSKit smoke test OK\n";

static int m_getattr(const char *path, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_uid = getuid();
    st->st_gid = getgid();
    st->st_atime = 1;
    st->st_mtime = 1;
    st->st_ctime = 1;

    if (strcmp(path, "/") == 0) {
        st->st_ino = 1;
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 2;
        return 0;
    }

    if (strcmp(path, "/hello.txt") == 0) {
        st->st_ino = 2;
        st->st_mode = S_IFREG | 0644;
        st->st_nlink = 1;
        st->st_size = sizeof(content) - 1;
        st->st_blocks = (st->st_size + 511) / 512;
        return 0;
    }

    return -ENOENT;
}

static int m_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                     off_t offset, struct fuse_file_info *fi) {
    (void)offset;
    (void)fi;
    if (strcmp(path, "/") != 0) return -ENOENT;
    filler(buf, ".", NULL, 0);
    filler(buf, "..", NULL, 0);
    filler(buf, "hello.txt", NULL, 0);
    return 0;
}

static int m_access(const char *path, int mask) {
    if (strcmp(path, "/") != 0 && strcmp(path, "/hello.txt") != 0) return -ENOENT;
    if (mask & W_OK) return -EACCES;
    return 0;
}

static int m_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, "/hello.txt") != 0) return -ENOENT;
    fi->fh = 42;
    return 0;
}

static int m_read(const char *path, char *buf, size_t size, off_t offset,
                  struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, "/hello.txt") != 0) return -ENOENT;
    size_t len = sizeof(content) - 1;
    if (offset < 0) return -EINVAL;
    if ((size_t)offset >= len) return 0;
    if ((size_t)offset + size > len) size = len - (size_t)offset;
    memcpy(buf, content + offset, size);
    return (int)size;
}

static int m_release(const char *path, struct fuse_file_info *fi) {
    (void)path;
    (void)fi;
    return 0;
}

#ifdef __APPLE__
static int m_getxattr(const char *path, const char *name, char *value,
                      size_t size, uint32_t position) {
    (void)value; (void)size; (void)position;
#else
static int m_getxattr(const char *path, const char *name, char *value,
                      size_t size) {
    (void)value; (void)size;
#endif
    (void)name;
    if (strcmp(path, "/") != 0 && strcmp(path, "/hello.txt") != 0) return -ENOENT;
    return -ENOATTR;
}

static int m_listxattr(const char *path, char *list, size_t size) {
    (void)list;
    (void)size;
    if (strcmp(path, "/") != 0 && strcmp(path, "/hello.txt") != 0) return -ENOENT;
    return 0;
}

static int m_statfs(const char *path, struct statvfs *st) {
    (void)path;
    memset(st, 0, sizeof(*st));
    st->f_bsize = 4096;
    st->f_frsize = 4096;
    st->f_blocks = 1024;
    st->f_bfree = 1024;
    st->f_bavail = 1024;
    st->f_files = 2;
    st->f_ffree = 100;
    st->f_namemax = 255;
    return 0;
}

static struct fuse_operations ops = {
    .getattr = m_getattr,
    .readdir = m_readdir,
    .access = m_access,
    .open = m_open,
    .read = m_read,
    .release = m_release,
    .getxattr = m_getxattr,
    .listxattr = m_listxattr,
    .statfs = m_statfs,
};

int main(int argc, char **argv) {
    return fuse_main(argc, argv, &ops, NULL);
}
EOF

section "Build minimal FUSE server"
FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"

if ! /usr/bin/cc "$SOURCE_FILE" -D_FILE_OFFSET_BITS=64 $FUSE_CFLAGS $FUSE_LIBS -o "$BINARY_FILE" 2>&1 | tee -a "$REPORT_FILE"; then
  log "FAIL: minimal FUSE server did not compile"
  exit 2
fi

/usr/bin/otool -L "$BINARY_FILE" 2>&1 | tee -a "$REPORT_FILE"

section "Prepare /Volumes mount point"
sudo -v

if /sbin/mount | grep -F " on $MOUNT_POINT " >/dev/null 2>&1; then
  sudo /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
fi

sudo /bin/rm -rf "$MOUNT_POINT"
sudo /bin/mkdir "$MOUNT_POINT"
sudo /usr/sbin/chown "$(id -u):$(id -g)" "$MOUNT_POINT"
/bin/chmod 700 "$MOUNT_POINT"
log "mountpoint=$MOUNT_POINT owner=$(id -u):$(id -g)"

section "Start FSKit mount"
log "command: $BINARY_FILE -f -o backend=fskit,uid=$(id -u),gid=$(id -g) $MOUNT_POINT"

"$BINARY_FILE" \
  -f \
  -o "backend=fskit,uid=$(id -u),gid=$(id -g)" \
  "$MOUNT_POINT" >"$SERVER_LOG" 2>&1 &
PID=$!
log "server_pid=$PID"

for _ in $(seq 1 30); do
  if [[ -r "$MOUNT_POINT/hello.txt" ]]; then
    PASS=1
    break
  fi
  sleep 0.2
done

section "Server process"
if kill -0 "$PID" >/dev/null 2>&1; then
  log "server process is still running"
else
  wait "$PID" >/dev/null 2>&1
  RC=$?
  log "server process exited rc=$RC"
fi

section "Mount table"
/sbin/mount 2>&1 | /usr/bin/grep -i -E 'macfuse|edp-fskit-smoke' | tee -a "$REPORT_FILE" || log "No matching mount table entry"

section "Mounted directory"
/bin/ls -la "$MOUNT_POINT" 2>&1 | tee -a "$REPORT_FILE" || true

section "Read hello.txt"
READ_RESULT="$(/bin/cat "$MOUNT_POINT/hello.txt" 2>&1)"
READ_RC=$?
printf '%s\n' "$READ_RESULT" | tee -a "$REPORT_FILE"
log "cat_rc=$READ_RC"

if [[ "$READ_RC" -eq 0 && "$READ_RESULT" == "EDP FSKit smoke test OK" ]]; then
  PASS=1
else
  PASS=0
fi

section "Minimal FUSE server log"
/bin/cat "$SERVER_LOG" 2>&1 | tee -a "$REPORT_FILE"

section "Latest EDP bridge log"
LATEST_BRIDGE="$(sudo /usr/bin/find /var/db/com.edp.usbvault/sessions -name bridge.log -type f -exec /usr/bin/stat -f '%m %N' {} \; 2>/dev/null | /usr/bin/sort -nr | /usr/bin/head -1 | /usr/bin/cut -d' ' -f2-)"
if [[ -n "$LATEST_BRIDGE" ]]; then
  log "$LATEST_BRIDGE"
  sudo /usr/bin/tail -n 40 "$LATEST_BRIDGE" 2>&1 | tee -a "$REPORT_FILE"
else
  log "No EDP bridge.log found"
fi

section "Recent macFUSE / FSKit system log"
/usr/bin/log show \
  --debug --info \
  --predicate 'subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"}' \
  --last 2m 2>&1 | /usr/bin/tail -n 250 | tee -a "$REPORT_FILE"

section "RESULT"
if [[ "$PASS" -eq 1 ]]; then
  log "PASS: standalone macFUSE 5.x FSKit mount works and hello.txt is readable."
  log "Interpretation: macFUSE/FSKit registration is functional; continue debugging EDP bridge implementation rather than system permissions."
else
  log "FAIL: standalone FSKit smoke test did not expose a readable hello.txt."
  log "Interpretation: inspect the minimal server and FSKit logs above before changing EDP bridge code."
fi

log "Full report saved to: $REPORT_FILE"

if [[ "$PASS" -eq 1 ]]; then
  exit 0
else
  exit 1
fi
