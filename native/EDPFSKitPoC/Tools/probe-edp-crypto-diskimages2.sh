#!/bin/bash
set -euo pipefail

MOUNT_POINT="/Volumes/edp-crypto-readonly"
WORK_DIR="${RUNNER_TEMP:-/tmp}/edp-crypto-di2"
PLAIN_IMAGE="${WORK_DIR}/plain.img"
CIPHER_IMAGE="${WORK_DIR}/cipher.img"
ATTACH_BIN="${WORK_DIR}/diskimages2-attach"
ENCRYPT_BIN="${WORK_DIR}/prepare-encrypted-image"
SWIFT_LIB="${WORK_DIR}/libEDPReadOnlyBridge.dylib"
FUSE_BIN="${WORK_DIR}/edp-readonly-fuse"
SERVER_LOG="${WORK_DIR}/server.log"
REPORT_FILE="${WORK_DIR}/report.txt"
ATTACH_PLAIN_LOG="${WORK_DIR}/attach-plain.log"
ATTACH_CIPHER_LOG="${WORK_DIR}/attach-cipher.log"
KEY_HEX="0123456789abcdeffedcba9876543210"
PLAIN_BSD=""
DECRYPTED_BSD=""
FUSE_PID=""
TEST_VOLUME="EDPCRYPTO"

mkdir -p "${WORK_DIR}"
: >"${SERVER_LOG}"
: >"${REPORT_FILE}"

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
    sleep 0.2
    kill -KILL "${FUSE_PID}" >/dev/null 2>&1 || true
  fi
  /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || sudo /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
  sudo /bin/rm -rf "${MOUNT_POINT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log "=== EDP encrypted reader -> macFUSE FSKit -> DiskImages2 -> native filesystem ==="
log "macOS=$(/usr/bin/sw_vers -productVersion)"
log "arch=$(/usr/bin/uname -m)"
log "libfuse=$(pkg-config --modversion fuse)"

/usr/bin/clang -fobjc-arc -fblocks \
  native/EDPFSKitPoC/Tools/DiskImages2Attach.m \
  -framework Foundation -o "${ATTACH_BIN}"

xcrun swiftc \
  native/EDPFSKitPoC/Extension/EDPCrypto.swift \
  native/EDPFSKitPoC/Tools/PrepareEncryptedDiskImage.swift \
  -o "${ENCRYPT_BIN}"

xcrun swiftc -emit-library -module-name EDPReadOnlyBridge \
  native/EDPFSKitPoC/Extension/EDPRawIO.swift \
  native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift \
  native/EDPFSKitPoC/Extension/EDPCrypto.swift \
  native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift \
  native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift \
  native/EDPFSKitPoC/Extension/EDPBlockDevice.swift \
  native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift \
  native/EDPFSKitPoC/Tools/EDPReadOnlyBlockCBridge.swift \
  -o "${SWIFT_LIB}"

/usr/bin/nm -gU "${SWIFT_LIB}" | tee "${WORK_DIR}/swift-symbols.txt"
for symbol in _edp_ro_open _edp_ro_size _edp_ro_read _edp_ro_close; do
  /usr/bin/grep -F "${symbol}" "${WORK_DIR}/swift-symbols.txt"
done
log "RESULT=EDP_SWIFT_C_SYMBOLS_EXPORTED"

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
/usr/bin/cc native/EDPFSKitPoC/Tools/EDPReadOnlyFuseBridge.c \
  -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} \
  "${SWIFT_LIB}" \
  -Wl,-rpath,"${WORK_DIR}" \
  -o "${FUSE_BIN}"
log "RESULT=EDP_CRYPTO_BRIDGE_TOOLS_BUILT"

python3 - "${PLAIN_IMAGE}" <<'PY'
import sys
with open(sys.argv[1], "wb") as handle:
    handle.truncate(128 * 1024 * 1024)
PY

"${ATTACH_BIN}" "${PLAIN_IMAGE}" | tee "${ATTACH_PLAIN_LOG}" | tee -a "${REPORT_FILE}"
PLAIN_BSD="$(/usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' "${ATTACH_PLAIN_LOG}" | /usr/bin/tail -1)"
[[ -n "${PLAIN_BSD}" && -b "/dev/${PLAIN_BSD}" ]]
/usr/sbin/diskutil eraseDisk ExFAT "${TEST_VOLUME}" MBRFormat "${PLAIN_BSD}" | tee -a "${REPORT_FILE}"

PLAIN_VOLUME="/Volumes/${TEST_VOLUME}"
for _ in $(seq 1 50); do
  [[ -d "${PLAIN_VOLUME}" ]] && break
  sleep 0.2
done
[[ -d "${PLAIN_VOLUME}" ]]

printf 'EDP encrypted block bridge read proof\n' >"${PLAIN_VOLUME}/proof.txt"
python3 - "${PLAIN_VOLUME}/payload.bin" <<'PY'
import sys
path = sys.argv[1]
with open(path, "wb") as handle:
    for block in range(1024):
        handle.write(bytes(((block * 17 + i * 29) & 0xff) for i in range(4096)))
PY
EXPECTED_SHA="$(/usr/bin/shasum -a 256 "${PLAIN_VOLUME}/payload.bin" | /usr/bin/awk '{print $1}')"
log "EXPECTED_PAYLOAD_SHA256=${EXPECTED_SHA}"
/bin/sync
/usr/sbin/diskutil unmountDisk "${PLAIN_BSD}" | tee -a "${REPORT_FILE}"
/usr/sbin/diskutil eject "${PLAIN_BSD}" | tee -a "${REPORT_FILE}"
PLAIN_BSD=""
log "RESULT=NATIVE_FILESYSTEM_FIXTURE_PREPARED"

"${ENCRYPT_BIN}" "${PLAIN_IMAGE}" "${CIPHER_IMAGE}" "${KEY_HEX}" | tee -a "${REPORT_FILE}"
[[ "$(/usr/bin/stat -f '%z' "${PLAIN_IMAGE}")" == "$(/usr/bin/stat -f '%z' "${CIPHER_IMAGE}")" ]]
if /usr/bin/cmp -s "${PLAIN_IMAGE}" "${CIPHER_IMAGE}"; then
  log "FAIL=ENCRYPTED_IMAGE_EQUALS_PLAINTEXT"
  exit 1
fi
log "RESULT=ENCRYPTED_BACKING_DIFFERS_FROM_PLAINTEXT"

sudo -v
sudo /bin/rm -rf "${MOUNT_POINT}"
sudo /bin/mkdir "${MOUNT_POINT}"
sudo /usr/sbin/chown "$(id -u):$(id -g)" "${MOUNT_POINT}"
/bin/chmod 700 "${MOUNT_POINT}"

DYLD_LIBRARY_PATH="${WORK_DIR}" \
  "${FUSE_BIN}" "${CIPHER_IMAGE}" "${KEY_HEX}" "${MOUNT_POINT}" \
  >"${SERVER_LOG}" 2>&1 &
FUSE_PID=$!

for _ in $(seq 1 60); do
  [[ -r "${MOUNT_POINT}/volume.raw" ]] && break
  if ! kill -0 "${FUSE_PID}" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
[[ -r "${MOUNT_POINT}/volume.raw" ]]
MOUNT_LINE="$(/sbin/mount | /usr/bin/grep -F " on ${MOUNT_POINT} " || true)"
log "MOUNT_LINE=${MOUNT_LINE}"
printf '%s\n' "${MOUNT_LINE}" | /usr/bin/grep -Eq '^macfuse://[^ ]+ on .+\(macfuse,.*fskit'
log "RESULT=EDP_CRYPTO_FUSE_BACKING_READY"

python3 - "${PLAIN_IMAGE}" "${MOUNT_POINT}/volume.raw" <<'PY'
import sys
plain, exposed = sys.argv[1:]
windows = [(0, 4096), (17, 8191), (65531, 7777), (3 * 1024 * 1024 + 5, 65519)]
with open(plain, "rb", buffering=0) as lhs, open(exposed, "rb", buffering=0) as rhs:
    for offset, length in windows:
        lhs.seek(offset)
        rhs.seek(offset)
        assert lhs.read(length) == rhs.read(length), (offset, length)
print("RESULT=EDP_ENCRYPTED_READER_RANDOM_WINDOWS_MATCH")
PY

"${ATTACH_BIN}" "${MOUNT_POINT}/volume.raw" | tee "${ATTACH_CIPHER_LOG}" | tee -a "${REPORT_FILE}"
DECRYPTED_BSD="$(/usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' "${ATTACH_CIPHER_LOG}" | /usr/bin/tail -1)"
[[ -n "${DECRYPTED_BSD}" && -b "/dev/${DECRYPTED_BSD}" ]]
log "DECRYPTED_BSD=${DECRYPTED_BSD}"
/usr/sbin/diskutil info "${DECRYPTED_BSD}" | tee -a "${REPORT_FILE}"
log "RESULT=EDP_DECRYPTED_VIEW_PUBLISHED_AS_BSD_DISK"

/usr/sbin/diskutil mountDisk "${DECRYPTED_BSD}" >/dev/null 2>&1 || true
DECRYPTED_VOLUME="/Volumes/${TEST_VOLUME}"
for _ in $(seq 1 75); do
  [[ -f "${DECRYPTED_VOLUME}/proof.txt" ]] && break
  sleep 0.2
done
[[ -f "${DECRYPTED_VOLUME}/proof.txt" ]]

PROOF="$(/bin/cat "${DECRYPTED_VOLUME}/proof.txt")"
ACTUAL_SHA="$(/usr/bin/shasum -a 256 "${DECRYPTED_VOLUME}/payload.bin" | /usr/bin/awk '{print $1}')"
log "PROOF=${PROOF}"
log "ACTUAL_PAYLOAD_SHA256=${ACTUAL_SHA}"
[[ "${PROOF}" == "EDP encrypted block bridge read proof" ]]
[[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]]
log "RESULT=APPLE_NATIVE_FILESYSTEM_READS_THROUGH_EDP_CRYPTO_OK"

set +e
/usr/bin/touch "${DECRYPTED_VOLUME}/must-not-write" >/dev/null 2>&1
WRITE_RC=$?
set -e
log "READONLY_WRITE_RC=${WRITE_RC}"
if [[ "${WRITE_RC}" -eq 0 ]]; then
  log "FAIL=READONLY_MILESTONE_ACCEPTED_WRITE"
  exit 1
fi
log "RESULT=EDP_READONLY_BLOCK_VIEW_ENFORCED"

/usr/sbin/diskutil unmountDisk "${DECRYPTED_BSD}" | tee -a "${REPORT_FILE}"
/usr/sbin/diskutil eject "${DECRYPTED_BSD}" | tee -a "${REPORT_FILE}"
DECRYPTED_BSD=""
log "RESULT=EDP_CRYPTO_DISKIMAGES2_TEARDOWN_OK"
log "RESULT=EDP_CRYPTO_MACFUSE_DISKIMAGES2_NATIVE_FS_READ_E2E_OK"
