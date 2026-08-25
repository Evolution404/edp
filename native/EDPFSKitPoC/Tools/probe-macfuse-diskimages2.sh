#!/bin/bash
set -euo pipefail

MOUNT_POINT="/Volumes/edp-macfuse-di2"
WORK_DIR="${RUNNER_TEMP:-/tmp}/edp-macfuse-di2"
SOURCE_FILE="${WORK_DIR}/blockfs.c"
FUSE_BIN="${WORK_DIR}/blockfs"
ATTACH_BIN="${WORK_DIR}/diskimages2-attach"
SERVER_LOG="${WORK_DIR}/server.log"
ATTACH_LOG="${WORK_DIR}/attach.log"
REPORT_FILE="${WORK_DIR}/report.txt"
PID=""
BSD_NAME=""
TEST_VOLUME="EDPDI2TEST"
CLEANUP_DONE=0

mkdir -p "${WORK_DIR}"
: >"${SERVER_LOG}"
: >"${ATTACH_LOG}"
: >"${REPORT_FILE}"

log() { printf '%s\n' "$*" | tee -a "${REPORT_FILE}"; }

is_backing_mounted() {
  /sbin/mount | /usr/bin/grep -F " on ${MOUNT_POINT} " >/dev/null 2>&1
}

run_bounded() {
  local timeout_s="$1"
  shift
  "$@" &
  local command_pid=$!
  local deadline=$((SECONDS + timeout_s))

  while kill -0 "${command_pid}" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      kill -TERM "${command_pid}" >/dev/null 2>&1 || true
      sleep 0.2
      kill -KILL "${command_pid}" >/dev/null 2>&1 || true
      wait "${command_pid}" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 0.1
  done

  wait "${command_pid}"
}

stop_fuse_server() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" >/dev/null 2>&1; then
    kill -TERM "${PID}" >/dev/null 2>&1 || true
    sleep 0.2
    kill -KILL "${PID}" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if (( CLEANUP_DONE )); then
    return 0
  fi
  CLEANUP_DONE=1

  if [[ -n "${BSD_NAME}" ]]; then
    run_bounded 5 /usr/sbin/diskutil eject "${BSD_NAME}" >/dev/null 2>&1 || \
      run_bounded 5 /usr/sbin/diskutil unmountDisk force "${BSD_NAME}" >/dev/null 2>&1 || true
  fi

  # Keep the FUSE server alive while asking FSKit/macFUSE to dismantle the
  # mount. Killing the server first can strand the mount and make umount hang.
  if is_backing_mounted; then
    if ! run_bounded 5 /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1; then
      log "WARN=MACFUSE_BACKING_UNMOUNT_TIMEOUT_OR_FAILURE"
      run_bounded 5 sudo -n /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
    fi
  fi

  stop_fuse_server

  # Last-resort cleanup is also bounded so CI can always reach diagnostics.
  if is_backing_mounted; then
    log "WARN=MACFUSE_BACKING_RETRYING_FORCE_UNMOUNT"
    run_bounded 5 sudo -n /sbin/umount -f "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi

  if ! is_backing_mounted; then
    /bin/rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || sudo -n /bin/rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || true
  else
    log "ERROR=MACFUSE_BACKING_STILL_MOUNTED_AFTER_CLEANUP"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "=== macFUSE FSKit + Private DiskImages2 PoC ==="
log "macOS=$(/usr/bin/sw_vers -productVersion)"
log "arch=$(/usr/bin/uname -m)"
log "libfuse=$(pkg-config --modversion fuse)"

cat >"${SOURCE_FILE}" <<'EOF'
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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

static const uint64_t volume_size = 128ULL * 1024ULL * 1024ULL;
static const char *volume_path = "/volume.raw";
static unsigned char *storage;
static pthread_rwlock_t storage_lock = PTHREAD_RWLOCK_INITIALIZER;

static int m_getattr(const char *path, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_uid = getuid();
    st->st_gid = getgid();
    st->st_atime = 1;
    st->st_mtime = 1;
    st->st_ctime = 1;
    st->st_blksize = 4096;
    if (strcmp(path, "/") == 0) {
        st->st_ino = 1;
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 2;
        return 0;
    }
    if (strcmp(path, volume_path) == 0) {
        st->st_ino = 2;
        st->st_mode = S_IFREG | 0666;
        st->st_nlink = 1;
        st->st_size = (off_t)volume_size;
        st->st_blocks = (blkcnt_t)((volume_size + 511) / 512);
        return 0;
    }
    return -ENOENT;
}

static int m_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                     off_t offset, struct fuse_file_info *fi) {
    (void)offset; (void)fi;
    if (strcmp(path, "/") != 0) return -ENOENT;
    filler(buf, ".", NULL, 0);
    filler(buf, "..", NULL, 0);
    filler(buf, "volume.raw", NULL, 0);
    return 0;
}

static int m_access(const char *path, int mask) {
    (void)mask;
    return (strcmp(path, "/") == 0 || strcmp(path, volume_path) == 0) ? 0 : -ENOENT;
}

static int m_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    fi->fh = 42;
    return 0;
}

static int m_read(const char *path, char *buf, size_t size, off_t offset,
                  struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (offset < 0) return -EINVAL;
    if ((uint64_t)offset >= volume_size) return 0;
    if ((uint64_t)size > volume_size - (uint64_t)offset) size = (size_t)(volume_size - (uint64_t)offset);
    pthread_rwlock_rdlock(&storage_lock);
    memcpy(buf, storage + offset, size);
    pthread_rwlock_unlock(&storage_lock);
    return (int)size;
}

static int m_write(const char *path, const char *buf, size_t size, off_t offset,
                   struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (offset < 0) return -EINVAL;
    if ((uint64_t)offset > volume_size || (uint64_t)size > volume_size - (uint64_t)offset) return -ENOSPC;
    pthread_rwlock_wrlock(&storage_lock);
    memcpy(storage + offset, buf, size);
    pthread_rwlock_unlock(&storage_lock);
    return (int)size;
}

static int m_release(const char *path, struct fuse_file_info *fi) { (void)path; (void)fi; return 0; }
static int m_flush(const char *path, struct fuse_file_info *fi) { (void)fi; return strcmp(path, volume_path) == 0 ? 0 : -ENOENT; }
static int m_fsync(const char *path, int datasync, struct fuse_file_info *fi) { (void)datasync; return m_flush(path, fi); }

#ifdef __APPLE__
static int m_getxattr(const char *path, const char *name, char *value, size_t size, uint32_t position) {
    (void)value; (void)size; (void)position;
#else
static int m_getxattr(const char *path, const char *name, char *value, size_t size) {
    (void)value; (void)size;
#endif
    (void)name;
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    return -ENOATTR;
}

static int m_listxattr(const char *path, char *list, size_t size) {
    (void)list; (void)size;
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    return 0;
}

static int m_statfs(const char *path, struct statvfs *st) {
    (void)path;
    memset(st, 0, sizeof(*st));
    st->f_bsize = 4096; st->f_frsize = 4096;
    st->f_blocks = volume_size / 4096;
    st->f_bfree = st->f_bavail = 0;
    st->f_files = 2; st->f_ffree = 0; st->f_namemax = 255;
    return 0;
}

static struct fuse_operations ops = {
    .getattr = m_getattr,
    .readdir = m_readdir,
    .access = m_access,
    .open = m_open,
    .read = m_read,
    .write = m_write,
    .release = m_release,
    .flush = m_flush,
    .fsync = m_fsync,
    .getxattr = m_getxattr,
    .listxattr = m_listxattr,
    .statfs = m_statfs,
};

int main(int argc, char **argv) {
    storage = calloc(1, (size_t)volume_size);
    if (!storage) return 70;
    int rc = fuse_main(argc, argv, &ops, NULL);
    free(storage);
    return rc;
}
EOF

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
/usr/bin/cc "${SOURCE_FILE}" -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} -lpthread -o "${FUSE_BIN}"
/usr/bin/clang -fobjc-arc -fblocks \
  native/EDPFSKitPoC/Tools/DiskImages2Attach.m \
  -framework Foundation -o "${ATTACH_BIN}"
log "RESULT=POC_TOOLS_BUILT"

sudo -v
sudo /bin/rm -rf "${MOUNT_POINT}"
sudo /bin/mkdir "${MOUNT_POINT}"
sudo /usr/sbin/chown "$(id -u):$(id -g)" "${MOUNT_POINT}"
/bin/chmod 700 "${MOUNT_POINT}"

"${FUSE_BIN}" -f -o "backend=fskit,uid=$(id -u),gid=$(id -g)" "${MOUNT_POINT}" >"${SERVER_LOG}" 2>&1 &
PID=$!

for _ in $(seq 1 60); do
  [[ -r "${MOUNT_POINT}/volume.raw" ]] && break
  sleep 0.2
done
[[ -r "${MOUNT_POINT}/volume.raw" ]]
MOUNT_LINE="$(/sbin/mount | /usr/bin/grep -F " on ${MOUNT_POINT} " || true)"
log "MOUNT_LINE=${MOUNT_LINE}"
printf '%s\n' "${MOUNT_LINE}" | /usr/bin/grep -Eq '^macfuse://[^ ]+ on .+\(macfuse,.*fskit'
log "RESULT=MACFUSE_FSKIT_BACKING_READY"

"${ATTACH_BIN}" "${MOUNT_POINT}/volume.raw" | tee "${ATTACH_LOG}" | tee -a "${REPORT_FILE}"
BSD_NAME="$(/usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' "${ATTACH_LOG}" | /usr/bin/tail -1)"
[[ -n "${BSD_NAME}" ]]
[[ -b "/dev/${BSD_NAME}" ]]
log "RESULT=DISKIMAGES2_CREATED_BLOCK_DEVICE"
/usr/sbin/diskutil info "${BSD_NAME}" | tee -a "${REPORT_FILE}"

/usr/sbin/diskutil eraseDisk ExFAT "${TEST_VOLUME}" MBRFormat "${BSD_NAME}" | tee -a "${REPORT_FILE}"
log "RESULT=NATIVE_EXFAT_FORMAT_OK"

VOLUME_PATH="/Volumes/${TEST_VOLUME}"
for _ in $(seq 1 50); do
  [[ -d "${VOLUME_PATH}" ]] && break
  sleep 0.2
done
[[ -d "${VOLUME_PATH}" ]]
printf 'EDP macFUSE + DiskImages2 + native exFAT OK\n' >"${VOLUME_PATH}/proof.txt"
/bin/sync
PROOF="$(/bin/cat "${VOLUME_PATH}/proof.txt")"
log "PROOF=${PROOF}"
[[ "${PROOF}" == "EDP macFUSE + DiskImages2 + native exFAT OK" ]]
log "RESULT=NATIVE_EXFAT_MOUNT_READ_WRITE_OK"

/usr/sbin/diskutil unmount "${VOLUME_PATH}" | tee -a "${REPORT_FILE}"
/usr/sbin/diskutil eject "${BSD_NAME}" | tee -a "${REPORT_FILE}"
BSD_NAME=""
log "RESULT=DISKIMAGES2_TEARDOWN_OK"

cleanup
if is_backing_mounted; then
  log "ERROR=MACFUSE_FSKIT_BACKING_TEARDOWN_FAILED"
  exit 1
fi
trap - EXIT INT TERM
log "RESULT=MACFUSE_FSKIT_BACKING_TEARDOWN_OK"
log "RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK"
