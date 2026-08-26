#!/bin/bash
set -euo pipefail

WORK_DIR="${RUNNER_TEMP:-/tmp}/edp-crypto-di2-readwrite"
MOUNT_POINT="${EDP_RW_MOUNT_POINT:-/Volumes/edp-crypto-readwrite}"
PLAIN_IMAGE="${WORK_DIR}/plain.img"
CIPHER_IMAGE="${WORK_DIR}/cipher.img"
ATTACH_BIN="${WORK_DIR}/diskimages2-attach"
ENCRYPT_BIN="${WORK_DIR}/prepare-encrypted-image"
SWIFT_LIB="${WORK_DIR}/libEDPReadWriteBridge.dylib"
FUSE_BIN="${WORK_DIR}/edp-readwrite-fuse"
SERVER_LOG="${WORK_DIR}/server.log"
REPORT_FILE="${WORK_DIR}/report.txt"
ATTACH_LOG="${WORK_DIR}/attach.log"
KEY_HEX="0123456789abcdeffedcba9876543210"
TEST_VOLUME="EDPCRW"
DECRYPTED_BSD=""
DECRYPTED_VOLUME_BSD=""
PLAIN_BSD=""
FUSE_PID=""

mkdir -p "${WORK_DIR}"
: >"${SERVER_LOG}"
: >"${REPORT_FILE}"
: >"${ATTACH_LOG}"

log() { printf '%s\n' "$*" | tee -a "${REPORT_FILE}"; }

cleanup() {
  if [[ -n "${DECRYPTED_BSD}" ]]; then
    /usr/sbin/diskutil eject "${DECRYPTED_BSD}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PLAIN_BSD}" ]]; then
    /usr/sbin/diskutil eject "${PLAIN_BSD}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${FUSE_PID}" ]] && kill -0 "${FUSE_PID}" >/dev/null 2>&1; then
    kill -TERM "${FUSE_PID}" >/dev/null 2>&1 || true
    wait "${FUSE_PID}" >/dev/null 2>&1 || true
  fi
  /usr/sbin/diskutil unmount "${MOUNT_POINT}" >/dev/null 2>&1 || \
    /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

start_fuse() {
  : >"${SERVER_LOG}"
  DYLD_LIBRARY_PATH="${WORK_DIR}" \
    "${FUSE_BIN}" "${CIPHER_IMAGE}" "${KEY_HEX}" "${MOUNT_POINT}" \
    >"${SERVER_LOG}" 2>&1 &
  FUSE_PID=$!
  for _ in $(seq 1 100); do
    [[ -w "${MOUNT_POINT}/volume.raw" ]] && return 0
    if ! kill -0 "${FUSE_PID}" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  /bin/cat "${SERVER_LOG}" >&2
  return 1
}

stop_fuse() {
  if [[ -n "${FUSE_PID}" ]] && kill -0 "${FUSE_PID}" >/dev/null 2>&1; then
    kill -TERM "${FUSE_PID}" >/dev/null 2>&1 || true
    wait "${FUSE_PID}" >/dev/null 2>&1 || true
  fi
  FUSE_PID=""
  /usr/sbin/diskutil unmount "${MOUNT_POINT}" >/dev/null 2>&1 || \
    /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
}

attach_decrypted() {
  : >"${ATTACH_LOG}"
  "${ATTACH_BIN}" "${MOUNT_POINT}/volume.raw" \
    | tee "${ATTACH_LOG}" | tee -a "${REPORT_FILE}"
  DECRYPTED_BSD="$(/usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' "${ATTACH_LOG}" | /usr/bin/tail -1)"
  [[ -n "${DECRYPTED_BSD}" && -b "/dev/${DECRYPTED_BSD}" ]]

  local disk_info
  disk_info="$(/usr/sbin/diskutil info "${DECRYPTED_BSD}")"
  printf '%s\n' "${disk_info}" | tee -a "${REPORT_FILE}"
  printf '%s\n' "${disk_info}" | /usr/bin/grep -Eq 'Media Read-Only:[[:space:]]+No'

  for _ in $(seq 1 100); do
    if [[ -b "/dev/${DECRYPTED_BSD}s1" ]]; then
      DECRYPTED_VOLUME_BSD="${DECRYPTED_BSD}s1"
    fi
    [[ -n "${DECRYPTED_VOLUME_BSD}" && -d "/Volumes/${TEST_VOLUME}" ]] && return 0
    /usr/sbin/diskutil mountDisk "${DECRYPTED_BSD}" >/dev/null 2>&1 || true
    sleep 0.2
  done
  /usr/sbin/diskutil list "${DECRYPTED_BSD}" >&2 || true
  return 1
}

eject_decrypted() {
  /usr/sbin/diskutil unmountDisk "${DECRYPTED_BSD}" | tee -a "${REPORT_FILE}"
  /usr/sbin/diskutil eject "${DECRYPTED_BSD}" | tee -a "${REPORT_FILE}"
  DECRYPTED_BSD=""
  DECRYPTED_VOLUME_BSD=""
}

log "=== EDP encrypted read/write block -> DiskImages2 -> native ExFAT ==="
log "macOS=$(/usr/bin/sw_vers -productVersion)"
log "arch=$(/usr/bin/uname -m)"
log "libfuse=$(pkg-config --modversion fuse)"

if [[ ! -d "${MOUNT_POINT}" || ! -w "${MOUNT_POINT}" ]]; then
  log "FAIL=WRITABLE_FSKIT_MOUNTPOINT_REQUIRED:${MOUNT_POINT}"
  exit 73
fi

/usr/bin/clang -fobjc-arc -fblocks \
  native/EDPFSKitPoC/Tools/DiskImages2Attach.m \
  -framework Foundation -o "${ATTACH_BIN}"

xcrun swiftc -O \
  native/EDPFSKitPoC/Extension/EDPCrypto.swift \
  native/EDPFSKitPoC/Tools/PrepareEncryptedDiskImage.swift \
  -o "${ENCRYPT_BIN}"

xcrun swiftc -O -emit-library -module-name EDPReadWriteBridge \
  native/EDPFSKitPoC/Extension/EDPRawIO.swift \
  native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift \
  native/EDPFSKitPoC/Extension/EDPCrypto.swift \
  native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift \
  native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift \
  native/EDPFSKitPoC/Extension/EDPBlockDevice.swift \
  native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift \
  native/EDPFSKitPoC/Tools/EDPReadWriteBlockCBridge.swift \
  -o "${SWIFT_LIB}"

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
/usr/bin/cc native/EDPFSKitPoC/Tools/EDPReadWriteFuseBridge.c \
  -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} -framework Security \
  "${SWIFT_LIB}" -Wl,-rpath,"${WORK_DIR}" -o "${FUSE_BIN}"

for symbol in _edp_rw_open _edp_rw_open_device _edp_rw_open_device_fd _edp_rw_size _edp_rw_read \
  _edp_rw_write _edp_rw_sync _edp_rw_close; do
  /usr/bin/nm -gU "${SWIFT_LIB}" | /usr/bin/grep -F "${symbol}" >/dev/null
done
log "RESULT=EDP_READWRITE_BRIDGE_TOOLS_BUILT"

/usr/bin/truncate -s $((128 * 1024 * 1024)) "${PLAIN_IMAGE}"
"${ATTACH_BIN}" "${PLAIN_IMAGE}" >"${WORK_DIR}/attach-plain.log"
PLAIN_BSD="$(/usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' "${WORK_DIR}/attach-plain.log" | /usr/bin/tail -1)"
[[ -n "${PLAIN_BSD}" && -b "/dev/${PLAIN_BSD}" ]]
/usr/sbin/diskutil eraseDisk ExFAT "${TEST_VOLUME}" MBRFormat "${PLAIN_BSD}" \
  | tee -a "${REPORT_FILE}"
/usr/sbin/diskutil unmountDisk "${PLAIN_BSD}" >/dev/null
/usr/sbin/diskutil eject "${PLAIN_BSD}" >/dev/null
PLAIN_BSD=""
log "RESULT=NATIVE_EXFAT_WRITE_FIXTURE_PREPARED"

"${ENCRYPT_BIN}" "${PLAIN_IMAGE}" "${CIPHER_IMAGE}" "${KEY_HEX}" \
  | tee -a "${REPORT_FILE}"
CIPHER_SHA_BEFORE="$(/usr/bin/shasum -a 256 "${CIPHER_IMAGE}" | /usr/bin/awk '{print $1}')"
log "CIPHER_SHA256_BEFORE=${CIPHER_SHA_BEFORE}"

start_fuse
log "RESULT=EDP_CRYPTO_READWRITE_FUSE_READY"
attach_decrypted
RW_INFO="$(/usr/sbin/diskutil info "${DECRYPTED_VOLUME_BSD}")"
printf '%s\n' "${RW_INFO}" | /usr/bin/grep -Eq 'File System Personality:[[:space:]]+ExFAT'
printf '%s\n' "${RW_INFO}" | /usr/bin/grep -Eq 'Volume Read-Only:[[:space:]]+No'
log "RESULT=NATIVE_EXFAT_MOUNTED_READWRITE_THROUGH_EDP_CRYPTO"

PAYLOAD_PATH="/Volumes/${TEST_VOLUME}/edp-readwrite-proof.bin"
python3 - "${PAYLOAD_PATH}" <<'PY'
import sys
with open(sys.argv[1], "wb", buffering=0) as handle:
    for block in range(1024):
        handle.write(bytes(((block * 23 + index * 41 + 7) & 0xff) for index in range(4096)))
PY
/bin/sync
EXPECTED_SHA="$(/usr/bin/shasum -a 256 "${PAYLOAD_PATH}" | /usr/bin/awk '{print $1}')"
log "EXPECTED_PAYLOAD_SHA256=${EXPECTED_SHA}"
log "RESULT=NATIVE_FILESYSTEM_FILE_WRITE_READBACK_OK"

eject_decrypted
stop_fuse
CIPHER_SHA_AFTER="$(/usr/bin/shasum -a 256 "${CIPHER_IMAGE}" | /usr/bin/awk '{print $1}')"
log "CIPHER_SHA256_AFTER=${CIPHER_SHA_AFTER}"
[[ "${CIPHER_SHA_AFTER}" != "${CIPHER_SHA_BEFORE}" ]]
log "RESULT=EDP_ENCRYPTED_WRITE_CHANGED_CIPHERTEXT"

start_fuse
attach_decrypted
ACTUAL_SHA="$(/usr/bin/shasum -a 256 "${PAYLOAD_PATH}" | /usr/bin/awk '{print $1}')"
log "ACTUAL_PAYLOAD_SHA256=${ACTUAL_SHA}"
[[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]]
log "RESULT=EDP_FILESYSTEM_WRITE_SURVIVES_FULL_REMOUNT"

eject_decrypted
stop_fuse
log "RESULT=EDP_CRYPTO_DISKIMAGES2_NATIVE_FS_READWRITE_E2E_OK"
