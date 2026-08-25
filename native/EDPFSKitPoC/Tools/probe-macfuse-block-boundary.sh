#!/bin/bash
set -euo pipefail

MOUNT_POINT="/Volumes/edp-macfuse-block-boundary"
WORK_DIR="${RUNNER_TEMP:-/tmp}/edp-macfuse-boundary"
SOURCE_FILE="${WORK_DIR}/boundary.c"
BINARY_FILE="${WORK_DIR}/boundary"
SERVER_LOG="${WORK_DIR}/server.log"
REPORT_FILE="${WORK_DIR}/report.txt"
BEFORE_DEVICES="${WORK_DIR}/devices-before.txt"
AFTER_DEVICES="${WORK_DIR}/devices-after.txt"
PID=""

mkdir -p "${WORK_DIR}"
: >"${SERVER_LOG}"
: >"${REPORT_FILE}"

log() {
  printf '%s\n' "$*" | tee -a "${REPORT_FILE}"
}

snapshot_devices() {
  /bin/ls /dev/disk* /dev/rdisk* 2>/dev/null | /usr/bin/sort -u
}

cleanup() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" >/dev/null 2>&1; then
    kill -TERM "${PID}" >/dev/null 2>&1 || true
    sleep 0.2
    kill -KILL "${PID}" >/dev/null 2>&1 || true
  fi
  /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || sudo /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
  sudo /bin/rm -rf "${MOUNT_POINT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log "=== macFUSE block-publication boundary probe ==="
log "macOS=$(/usr/bin/sw_vers -productVersion)"
log "arch=$(/usr/bin/uname -m)"
log "uid=$(id -u) gid=$(id -g)"
log "libfuse=$(pkg-config --modversion fuse)"

cat >"${SOURCE_FILE}" <<'EOF'
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <errno.h>
#include <stdint.h>
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

static const uint64_t volume_size = 8ULL * 1024ULL * 1024ULL;
static const char *volume_path = "/volume.raw";

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
        st->st_mode = S_IFREG | 0644;
        st->st_nlink = 1;
        st->st_size = (off_t)volume_size;
        st->st_blocks = (blkcnt_t)((volume_size + 511) / 512);
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
    filler(buf, "volume.raw", NULL, 0);
    return 0;
}

static int m_access(const char *path, int mask) {
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    if (mask & X_OK && strcmp(path, "/") != 0) return -EACCES;
    return 0;
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
    if ((uint64_t)size > volume_size - (uint64_t)offset) {
        size = (size_t)(volume_size - (uint64_t)offset);
    }
    for (size_t i = 0; i < size; ++i) {
        buf[i] = (char)(((uint64_t)offset + i) & 0xff);
    }
    return (int)size;
}

static int m_write(const char *path, const char *buf, size_t size, off_t offset,
                   struct fuse_file_info *fi) {
    (void)buf;
    (void)fi;
    if (strcmp(path, volume_path) != 0) return -ENOENT;
    if (offset < 0) return -EINVAL;
    if ((uint64_t)offset > volume_size || (uint64_t)size > volume_size - (uint64_t)offset) return -ENOSPC;
    return (int)size;
}

static int m_release(const char *path, struct fuse_file_info *fi) {
    (void)path;
    (void)fi;
    return 0;
}

static int m_flush(const char *path, struct fuse_file_info *fi) {
    (void)fi;
    return strcmp(path, volume_path) == 0 ? 0 : -ENOENT;
}

static int m_fsync(const char *path, int datasync, struct fuse_file_info *fi) {
    (void)datasync;
    return m_flush(path, fi);
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
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    return -ENOATTR;
}

static int m_listxattr(const char *path, char *list, size_t size) {
    (void)list;
    (void)size;
    if (strcmp(path, "/") != 0 && strcmp(path, volume_path) != 0) return -ENOENT;
    return 0;
}

static int m_statfs(const char *path, struct statvfs *st) {
    (void)path;
    memset(st, 0, sizeof(*st));
    st->f_bsize = 4096;
    st->f_frsize = 4096;
    st->f_blocks = volume_size / 4096;
    st->f_bfree = 0;
    st->f_bavail = 0;
    st->f_files = 2;
    st->f_ffree = 0;
    st->f_namemax = 255;
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
    return fuse_main(argc, argv, &ops, NULL);
}
EOF

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
/usr/bin/cc "${SOURCE_FILE}" -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} -o "${BINARY_FILE}"

sudo -v
sudo /bin/rm -rf "${MOUNT_POINT}"
sudo /bin/mkdir "${MOUNT_POINT}"
sudo /usr/sbin/chown "$(id -u):$(id -g)" "${MOUNT_POINT}"
/bin/chmod 700 "${MOUNT_POINT}"

snapshot_devices >"${BEFORE_DEVICES}"
log "BSD_DEVICE_COUNT_BEFORE=$(wc -l <"${BEFORE_DEVICES}" | tr -d ' ')"

log "COMMAND=${BINARY_FILE} -f -o backend=fskit,uid=$(id -u),gid=$(id -g) ${MOUNT_POINT}"
"${BINARY_FILE}" -f -o "backend=fskit,uid=$(id -u),gid=$(id -g)" "${MOUNT_POINT}" >"${SERVER_LOG}" 2>&1 &
PID=$!
log "SERVER_PID=${PID}"

READY=0
for _ in $(seq 1 50); do
  if [[ -r "${MOUNT_POINT}/volume.raw" ]]; then
    READY=1
    break
  fi
  if ! kill -0 "${PID}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if [[ "${READY}" != "1" ]]; then
  log "FAIL=MACFUSE_MOUNT_NOT_READY"
  /bin/cat "${SERVER_LOG}" | tee -a "${REPORT_FILE}" || true
  exit 1
fi

MOUNT_LINE="$(/sbin/mount | /usr/bin/grep -F " on ${MOUNT_POINT} " || true)"
log "MOUNT_LINE=${MOUNT_LINE}"
if ! printf '%s\n' "${MOUNT_LINE}" | /usr/bin/grep -Eq '^macfuse://[^ ]+ on .+\(macfuse,.*fskit'; then
  log "FAIL=EXPECTED_GENERIC_MACFUSE_FSKIT_MOUNT_NOT_OBSERVED"
  exit 1
fi
log "RESULT=MACFUSE_GENERIC_FSKIT_MOUNT_OK"

VIRTUAL_FILE="${MOUNT_POINT}/volume.raw"
/usr/bin/stat -f 'VIRTUAL_STAT=mode=%Sp type=%HT size=%z' "${VIRTUAL_FILE}" | tee -a "${REPORT_FILE}"
if [[ ! -f "${VIRTUAL_FILE}" || -b "${VIRTUAL_FILE}" || -c "${VIRTUAL_FILE}" ]]; then
  log "FAIL=VIRTUAL_OBJECT_NOT_REGULAR_FILE"
  exit 1
fi
log "RESULT=MACFUSE_EXPOSED_OBJECT_REGULAR_FILE"

EXPECTED_HEX="000102030405060708090a0b0c0d0e0f"
ACTUAL_HEX="$(python3 - "${VIRTUAL_FILE}" <<'PY'
import sys
with open(sys.argv[1], "rb", buffering=0) as handle:
    print(handle.read(16).hex())
PY
)"
log "READ_HEAD_HEX=${ACTUAL_HEX}"
if [[ "${ACTUAL_HEX}" != "${EXPECTED_HEX}" ]]; then
  log "FAIL=FUSE_RANDOM_READ_MISMATCH"
  exit 1
fi
log "RESULT=MACFUSE_RANDOM_READ_OK"

snapshot_devices >"${AFTER_DEVICES}"
log "BSD_DEVICE_COUNT_AFTER=$(wc -l <"${AFTER_DEVICES}" | tr -d ' ')"
NEW_DEVICES="$(/usr/bin/comm -13 "${BEFORE_DEVICES}" "${AFTER_DEVICES}" || true)"
if [[ -n "${NEW_DEVICES}" ]]; then
  log "FAIL=UNEXPECTED_NEW_BSD_DEVICE"
  printf '%s\n' "${NEW_DEVICES}" | tee -a "${REPORT_FILE}"
  exit 1
fi
log "RESULT=NO_NEW_BSD_BLOCK_DEVICE"

DISKUTIL_INFO_RC="$(python3 - "${VIRTUAL_FILE}" "${REPORT_FILE}" <<'PY'
import subprocess
import sys
path, report = sys.argv[1:]
try:
    completed = subprocess.run(
        ["/usr/sbin/diskutil", "info", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=5,
    )
    rc = completed.returncode
    output = completed.stdout
except subprocess.TimeoutExpired as error:
    rc = 124
    output = (error.stdout or b"") + b"\nDISKUTIL_PROBE_TIMEOUT=5s\n"
with open(report, "ab") as handle:
    handle.write(output)
print(rc)
PY
)"
log "DISKUTIL_INFO_RC=${DISKUTIL_INFO_RC}"
if [[ "${DISKUTIL_INFO_RC}" -eq 0 ]]; then
  log "FAIL=DISKUTIL_ACCEPTED_FUSE_REGULAR_FILE_AS_DISK"
  exit 1
fi
log "RESULT=DISKUTIL_REJECTS_FUSE_REGULAR_FILE_AS_DISK"
log "RESULT=MACFUSE_IS_FILESYSTEM_TRANSPORT_NOT_BLOCK_PUBLISHER"
