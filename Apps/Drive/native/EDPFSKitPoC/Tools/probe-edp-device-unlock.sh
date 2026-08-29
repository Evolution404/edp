#!/bin/bash
set -euo pipefail

WORK_DIR="${RUNNER_TEMP:-/tmp}/edp-device-unlock"
MOUNT_POINT="/Volumes/edp-device-unlock-smoke"
SWIFT_LIB="${WORK_DIR}/libEDPReadOnlyBridge.dylib"
FUSE_BIN="${WORK_DIR}/edp-readonly-fuse"
RAW_FIXTURE="${WORK_DIR}/real-metadata-sparse-device.img"
SERVER_LOG="${WORK_DIR}/server.log"
WRONG_PASSWORD_LOG="${WORK_DIR}/wrong-password.log"
REPORT_FILE="${WORK_DIR}/report.txt"
GOLDEN_JSON="fixtures/golden/disks.json"
LBA11_FIXTURE="fixtures/real_disks/disk4/LBA11.bin"
LBA12_FIXTURE="fixtures/real_disks/disk4/LBA12.bin"
FUSE_PID=""

mkdir -p "${WORK_DIR}"
: >"${REPORT_FILE}"
: >"${SERVER_LOG}"
: >"${WRONG_PASSWORD_LOG}"

log() { printf '%s\n' "$*" | tee -a "${REPORT_FILE}"; }

cleanup() {
  if [[ -n "${FUSE_PID}" ]] && kill -0 "${FUSE_PID}" >/dev/null 2>&1; then
    kill -TERM "${FUSE_PID}" >/dev/null 2>&1 || true
    sleep 0.2
    kill -KILL "${FUSE_PID}" >/dev/null 2>&1 || true
  fi
  /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || sudo /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
  sudo /bin/rm -rf "${MOUNT_POINT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log "=== EDP product unlock boundary -> password FD -> macFUSE FSKit smoke ==="
log "macOS=$(/usr/bin/sw_vers -productVersion)"
log "arch=$(/usr/bin/uname -m)"
log "libfuse=$(pkg-config --modversion fuse)"

xcrun swiftc -O -emit-library -module-name EDPReadOnlyBridge \
  native/EDPFSKitPoC/Extension/EDPRawIO.swift \
  native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift \
  native/EDPFSKitPoC/Extension/EDPCrypto.swift \
  native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift \
  native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift \
  native/EDPFSKitPoC/Extension/EDPBlockDevice.swift \
  native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift \
  native/EDPFSKitPoC/Tools/EDPReadOnlyBlockCBridge.swift \
  -o "${SWIFT_LIB}"

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
/usr/bin/cc native/EDPFSKitPoC/Tools/EDPReadOnlyFuseBridge.c \
  -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} \
  -framework Security \
  "${SWIFT_LIB}" \
  -Wl,-rpath,"${WORK_DIR}" \
  -o "${FUSE_BIN}"
log "RESULT=EDP_DEVICE_MODE_BRIDGE_BUILT"

readarray_value() {
  local field="$1"
  python3 - "${GOLDEN_JSON}" "${field}" <<'PY'
import json
import sys
path, field = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    root = json.load(handle)
disk = next(item for item in root["disks"] if item["name"] == "disk4_real_lexar")
entry = next(item for item in disk["entries"] if int(item["partition_type"]) == 2)
values = {
    "vid": disk["lba11_params"]["vid"],
    "pid": disk["lba11_params"]["pid"],
    "device_size": int(disk["lba11_params"]["size_bytes"]),
    "partition_size": int(entry["size_bytes"]),
}
print(values[field])
PY
}

DEVICE_VID="$(readarray_value vid)"
DEVICE_PID="$(readarray_value pid)"
DEVICE_SIZE="$(readarray_value device_size)"
PARTITION_SIZE="$(readarray_value partition_size)"

python3 - "${RAW_FIXTURE}" "${DEVICE_SIZE}" "${LBA11_FIXTURE}" "${LBA12_FIXTURE}" <<'PY'
import os
import sys
raw_path, size_text, lba11_path, lba12_path = sys.argv[1:]
size = int(size_text)
with open(lba11_path, "rb") as handle:
    lba11 = handle.read()
with open(lba12_path, "rb") as handle:
    lba12 = handle.read()
assert len(lba11) == 512
assert len(lba12) == 512
with open(raw_path, "wb", buffering=0) as handle:
    handle.truncate(size)
    handle.seek(11 * 512)
    handle.write(lba11)
    handle.seek(12 * 512)
    handle.write(lba12)
st = os.stat(raw_path)
assert st.st_size == size
print("RESULT=EDP_REAL_METADATA_SPARSE_DEVICE_READY")
PY
log "DEVICE_DECLARED_SIZE=${DEVICE_SIZE}"
log "EXPECTED_PARTITION_SIZE=${PARTITION_SIZE}"
log "RESULT=EDP_REAL_METADATA_FIXTURE_READY"

sudo -v
sudo /bin/rm -rf "${MOUNT_POINT}"
sudo /bin/mkdir "${MOUNT_POINT}"
sudo /usr/sbin/chown "$(id -u):$(id -g)" "${MOUNT_POINT}"
/bin/chmod 700 "${MOUNT_POINT}"

exec 4< <(printf '%s' 'ci-intentionally-wrong-password')
set +e
DYLD_LIBRARY_PATH="${WORK_DIR}" \
  "${FUSE_BIN}" --device "${RAW_FIXTURE}" "${DEVICE_VID}" "${DEVICE_PID}" \
  "${DEVICE_SIZE}" 2 4 "${MOUNT_POINT}" \
  >"${WRONG_PASSWORD_LOG}" 2>&1 4<&4
WRONG_PASSWORD_RC=$?
set -e
exec 4<&-
log "WRONG_PASSWORD_RC=${WRONG_PASSWORD_RC}"
if [[ "${WRONG_PASSWORD_RC}" -ne 65 ]]; then
  /bin/cat "${WRONG_PASSWORD_LOG}" >&2
  log "FAIL=EDP_DEVICE_MODE_WRONG_PASSWORD_NOT_REJECTED"
  exit 1
fi
/usr/bin/grep -F 'EDP_FUSE_BRIDGE_OPEN_DEVICE_FAILED' "${WRONG_PASSWORD_LOG}" >/dev/null
log "RESULT=EDP_DEVICE_MODE_WRONG_PASSWORD_REJECTED"

exec 3< <(python3 - "${GOLDEN_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    root = json.load(handle)
disk = next(item for item in root["disks"] if item["name"] == "disk4_real_lexar")
sys.stdout.buffer.write(disk["password"].encode("utf-8"))
PY
)

DYLD_LIBRARY_PATH="${WORK_DIR}" \
  "${FUSE_BIN}" --device "${RAW_FIXTURE}" "${DEVICE_VID}" "${DEVICE_PID}" \
  "${DEVICE_SIZE}" 2 3 "${MOUNT_POINT}" \
  >"${SERVER_LOG}" 2>&1 3<&3 &
FUSE_PID=$!
exec 3<&-

for _ in $(seq 1 60); do
  [[ -r "${MOUNT_POINT}/volume.raw" ]] && break
  if ! kill -0 "${FUSE_PID}" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
if [[ ! -r "${MOUNT_POINT}/volume.raw" ]]; then
  /bin/cat "${SERVER_LOG}" >&2
  log "FAIL=EDP_DEVICE_MODE_FUSE_NOT_READY"
  exit 1
fi

MOUNT_LINE="$(/sbin/mount | /usr/bin/grep -F " on ${MOUNT_POINT} " || true)"
log "MOUNT_LINE=${MOUNT_LINE}"
printf '%s\n' "${MOUNT_LINE}" | /usr/bin/grep -Eq '^macfuse://[^ ]+ on .+\(macfuse,.*fskit'
ACTUAL_SIZE="$(/usr/bin/stat -f '%z' "${MOUNT_POINT}/volume.raw")"
log "ACTUAL_PARTITION_SIZE=${ACTUAL_SIZE}"
[[ "${ACTUAL_SIZE}" == "${PARTITION_SIZE}" ]]
log "RESULT=EDP_DEVICE_UNLOCK_EXPOSED_DESCRIPTOR_SIZE_OK"

python3 - "${MOUNT_POINT}/volume.raw" "${PARTITION_SIZE}" <<'PY'
import sys
path, size_text = sys.argv[1:]
size = int(size_text)
windows = [
    (0, 1),
    (17, 31),
    (65531, 7777),
    (size - 4096, 4096),
]
with open(path, "rb", buffering=0) as handle:
    for offset, length in windows:
        handle.seek(offset)
        data = handle.read(length)
        assert len(data) == length, (offset, length, len(data))
print("RESULT=EDP_DEVICE_MODE_RANDOM_READS_OK")
PY
log "RESULT=EDP_DEVICE_PASSWORD_FD_TRANSPORT_OK"

kill -TERM "${FUSE_PID}" >/dev/null 2>&1 || true
wait "${FUSE_PID}" >/dev/null 2>&1 || true
FUSE_PID=""
/sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || sudo /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
log "RESULT=EDP_PRODUCT_UNLOCK_FUSE_DEVICE_MODE_OK"
