#!/bin/bash
set -euo pipefail

WORK_DIR="${RUNNER_TEMP:-/tmp}/edp-crypto-ntfs3g-readwrite"
BRIDGE_MOUNT="${EDP_RW_MOUNT_POINT:-/Volumes/edp-crypto-readwrite}"
NTFS_MOUNT="${EDP_NTFS_MOUNT_POINT:-/Volumes/EDPNTFSRW}"
NTFS_RUNTIME="${EDP_NTFS_RUNTIME:?EDP_NTFS_RUNTIME must point to the built ntfs-3g runtime directory}"
NTFS_POLICY_RENDERER="${EDP_NTFS_POLICY_RENDERER:?EDP_NTFS_POLICY_RENDERER must point to the shared policy renderer}"
PLAIN_IMAGE="${WORK_DIR}/plain-ntfs.img"
CIPHER_IMAGE="${WORK_DIR}/cipher-ntfs.img"
ATTACH_BIN="${WORK_DIR}/diskimages2-attach"
ENCRYPT_BIN="${WORK_DIR}/prepare-encrypted-image"
SWIFT_LIB="${WORK_DIR}/libEDPReadWriteBridge.dylib"
FUSE_BIN="${WORK_DIR}/edp-readwrite-fuse"
SERVER_LOG="${WORK_DIR}/bridge.log"
NTFS_LOG="${WORK_DIR}/ntfs-3g.log"
ATTACH_LOG="${WORK_DIR}/attach.log"
REPORT_FILE="${WORK_DIR}/report.txt"
KEY_HEX="0123456789abcdeffedcba9876543210"
TEST_VOLUME="EDPRWTEST"
FUSE_PID=""
NTFS_PID=""
NTFS_EXIT_STATUS=""
DECRYPTED_BSD=""
CLEANUP_DONE=0

mkdir -p "${WORK_DIR}"
: >"${SERVER_LOG}"
: >"${NTFS_LOG}"
: >"${ATTACH_LOG}"
: >"${REPORT_FILE}"

log() { printf '%s\n' "$*" | tee -a "${REPORT_FILE}"; }

is_mounted() {
  local mountpoint="$1"
  /sbin/mount | /usr/bin/grep -F " on ${mountpoint} " >/dev/null 2>&1
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

stop_process() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "${pid}" >/dev/null 2>&1 || return 0
      sleep 0.1
    done
    kill -KILL "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

ntfs_process_state() {
  if [[ -z "${NTFS_PID}" ]]; then
    printf 'none'
    return 0
  fi
  local state
  state="$(/bin/ps -o state= -p "${NTFS_PID}" 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)"
  printf '%s' "${state:-exited}"
}

record_ntfs_exit_if_dead() {
  [[ -n "${NTFS_PID}" ]] || return 0
  local state
  state="$(ntfs_process_state)"
  if [[ "${state}" != "exited" && "${state}" != Z* ]]; then
    return 0
  fi
  if [[ -z "${NTFS_EXIT_STATUS}" ]]; then
    set +e
    wait "${NTFS_PID}"
    NTFS_EXIT_STATUS=$?
    set -e
    log "NTFS_PID_EXIT_STATUS=${NTFS_EXIT_STATUS}"
    log "NTFS_LOG_BEGIN"
    while IFS= read -r line; do
      log "NTFS_LOG=${line}"
    done <"${NTFS_LOG}"
    log "NTFS_LOG_END"
  fi
  return 1
}

diagnose_ntfs_state() {
  local label="$1"
  local state mounted stat_rc readdir_rc
  state="$(ntfs_process_state)"
  if is_mounted "${NTFS_MOUNT}"; then mounted=YES; else mounted=NO; fi
  set +e
  /usr/bin/stat -f '%d:%i:%HT' "${NTFS_MOUNT}" >/dev/null 2>&1
  stat_rc=$?
  /bin/ls -la "${NTFS_MOUNT}" >/dev/null 2>&1
  readdir_rc=$?
  set -e
  log "NTFS_STATE label=${label} pid=${NTFS_PID:-none} process_state=${state} mounted=${mounted} stat_rc=${stat_rc} readdir_rc=${readdir_rc}"
  if ! record_ntfs_exit_if_dead; then
    return 1
  fi
  [[ "${mounted}" == YES && ${stat_rc} -eq 0 && ${readdir_rc} -eq 0 ]]
}

unmount_ntfs() {
  if is_mounted "${NTFS_MOUNT}"; then
    run_bounded 5 /sbin/umount "${NTFS_MOUNT}" >/dev/null 2>&1 || \
      run_bounded 5 sudo -n /sbin/umount "${NTFS_MOUNT}" >/dev/null 2>&1 || true
  fi
  stop_process "${NTFS_PID}"
  NTFS_PID=""
}

unmount_bridge() {
  if is_mounted "${BRIDGE_MOUNT}"; then
    run_bounded 5 /sbin/umount "${BRIDGE_MOUNT}" >/dev/null 2>&1 || \
      run_bounded 5 sudo -n /sbin/umount "${BRIDGE_MOUNT}" >/dev/null 2>&1 || true
  fi
  stop_process "${FUSE_PID}"
  FUSE_PID=""
}

cleanup() {
  if (( CLEANUP_DONE )); then return 0; fi
  CLEANUP_DONE=1

  if [[ -n "${NTFS_PID}" ]]; then
    diagnose_ntfs_state "CLEANUP_ENTRY" || true
    record_ntfs_exit_if_dead || true
  fi
  unmount_ntfs
  if [[ -n "${DECRYPTED_BSD}" ]]; then
    run_bounded 5 /usr/sbin/diskutil eject "${DECRYPTED_BSD}" >/dev/null 2>&1 || \
      run_bounded 5 /usr/sbin/diskutil unmountDisk force "${DECRYPTED_BSD}" >/dev/null 2>&1 || true
    DECRYPTED_BSD=""
  fi
  unmount_bridge

  if ! is_mounted "${NTFS_MOUNT}"; then
    /bin/rmdir "${NTFS_MOUNT}" >/dev/null 2>&1 || sudo -n /bin/rmdir "${NTFS_MOUNT}" >/dev/null 2>&1 || true
  fi
  if ! is_mounted "${BRIDGE_MOUNT}"; then
    /bin/rmdir "${BRIDGE_MOUNT}" >/dev/null 2>&1 || sudo -n /bin/rmdir "${BRIDGE_MOUNT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_bridge() {
  for _ in $(seq 1 100); do
    [[ -w "${BRIDGE_MOUNT}/volume.raw" ]] && return 0
    if ! kill -0 "${FUSE_PID}" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  /bin/cat "${SERVER_LOG}" >&2
  return 1
}

start_bridge() {
  : >"${SERVER_LOG}"
  DYLD_LIBRARY_PATH="${WORK_DIR}" \
    "${FUSE_BIN}" "${CIPHER_IMAGE}" "${KEY_HEX}" "${BRIDGE_MOUNT}" \
    >"${SERVER_LOG}" 2>&1 &
  FUSE_PID=$!
  wait_for_bridge
  local mount_line
  mount_line="$(/sbin/mount | /usr/bin/grep -F " on ${BRIDGE_MOUNT} " || true)"
  log "BRIDGE_MOUNT_LINE=${mount_line}"
  printf '%s\n' "${mount_line}" | /usr/bin/grep -Eq '^macfuse://[^ ]+ on .+\(macfuse,.*fskit'
}

attach_decrypted() {
  : >"${ATTACH_LOG}"
  "${ATTACH_BIN}" --writable-noautomount "${BRIDGE_MOUNT}/volume.raw" \
    | tee "${ATTACH_LOG}" | tee -a "${REPORT_FILE}"
  DECRYPTED_BSD="$(/usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' "${ATTACH_LOG}" | /usr/bin/tail -1)"
  [[ -n "${DECRYPTED_BSD}" && -b "/dev/${DECRYPTED_BSD}" ]]

  local disk_info
  disk_info="$(/usr/sbin/diskutil info "${DECRYPTED_BSD}")"
  printf '%s\n' "${disk_info}" | tee -a "${REPORT_FILE}"
  printf '%s\n' "${disk_info}" | /usr/bin/grep -Eq 'Media Read-Only:[[:space:]]+No'
}

start_ntfs() {
  : >"${NTFS_LOG}"
  local source="${BRIDGE_MOUNT}/volume.raw"
  log "STEP=NTFS3G_PROBE_BEGIN"
  DYLD_LIBRARY_PATH="${NTFS_RUNTIME}/lib" \
    "${NTFS_RUNTIME}/bin/ntfs-3g.probe" --readwrite "${source}"
  log "STEP=NTFS3G_PROBE_OK"
  local label
  label="$(DYLD_LIBRARY_PATH="${NTFS_RUNTIME}/lib" \
    "${NTFS_RUNTIME}/bin/ntfslabel" "${source}" | /usr/bin/tr -d '\r\n')"
  [[ "${label}" == "${TEST_VOLUME}" ]]
  log "STEP=NTFSLABEL_OK"

  local ntfs_options=()
  while IFS= read -r option; do
    [[ -n "${option}" ]] && ntfs_options+=("-o" "${option}")
  done < <("${NTFS_POLICY_RENDERER}" "$(id -u)" "$(id -g)" "${TEST_VOLUME}")
  [[ ${#ntfs_options[@]} -gt 0 ]]
  log "NTFS_SHARED_POLICY=$(printf '%s ' "${ntfs_options[@]}")"

  log "STEP=NTFS3G_MOUNT_BEGIN"
  DYLD_LIBRARY_PATH="${NTFS_RUNTIME}/lib" \
    "${NTFS_RUNTIME}/bin/ntfs-3g" \
      "${ntfs_options[@]}" \
      -o debug \
      "${source}" "${NTFS_MOUNT}" \
      >"${NTFS_LOG}" 2>&1 &
  NTFS_PID=$!
  NTFS_EXIT_STATUS=""
  log "NTFS_PID=${NTFS_PID}"

  for _ in $(seq 1 100); do
    is_mounted "${NTFS_MOUNT}" && break
    if ! kill -0 "${NTFS_PID}" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  if ! is_mounted "${NTFS_MOUNT}"; then
    /bin/cat "${NTFS_LOG}" >&2
    return 1
  fi
  local mount_line
  mount_line="$(/sbin/mount | /usr/bin/grep -F " on ${NTFS_MOUNT} " || true)"
  log "NTFS_MOUNT_LINE=${mount_line}"
  printf '%s\n' "${mount_line}" | /usr/bin/grep -Eq '^macfuse://[^ ]+ on .+\(macfuse,.*fskit'

  diagnose_ntfs_state "MOUNT_T0"
  sleep 0.1
  diagnose_ntfs_state "MOUNT_T100MS"
  sleep 0.4
  diagnose_ntfs_state "MOUNT_T500MS"
  sleep 0.5
  diagnose_ntfs_state "MOUNT_T1S"
}

eject_decrypted() {
  if [[ -n "${DECRYPTED_BSD}" ]]; then
    run_bounded 5 /usr/sbin/diskutil eject "${DECRYPTED_BSD}" | tee -a "${REPORT_FILE}"
    DECRYPTED_BSD=""
  fi
}

log "=== EDP encrypted read/write block -> DiskImages2 -> bundled NTFS-3G FSKit ==="
log "macOS=$(/usr/bin/sw_vers -productVersion)"
log "arch=$(/usr/bin/uname -m)"
log "libfuse=$(pkg-config --modversion fuse)"

for tool in \
  "${NTFS_RUNTIME}/bin/ntfs-3g" \
  "${NTFS_RUNTIME}/bin/ntfs-3g.probe" \
  "${NTFS_RUNTIME}/bin/ntfslabel" \
  "${NTFS_RUNTIME}/test-tools/mkntfs" \
  "${NTFS_POLICY_RENDERER}"; do
  [[ -x "${tool}" ]] || { log "FAIL=MISSING_NTFS_TOOL:${tool}"; exit 69; }
done
for mountpoint in "${BRIDGE_MOUNT}" "${NTFS_MOUNT}"; do
  if [[ ! -d "${mountpoint}" || ! -w "${mountpoint}" ]]; then
    log "FAIL=WRITABLE_MOUNTPOINT_REQUIRED:${mountpoint}"
    exit 73
  fi
done

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
  -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} \
  "${SWIFT_LIB}" -Wl,-rpath,"${WORK_DIR}" -o "${FUSE_BIN}"
log "RESULT=EDP_NTFS3G_READWRITE_TOOLS_BUILT"

/usr/bin/truncate -s $((128 * 1024 * 1024)) "${PLAIN_IMAGE}"
"${NTFS_RUNTIME}/test-tools/mkntfs" -F -L "${TEST_VOLUME}" "${PLAIN_IMAGE}" \
  >>"${REPORT_FILE}" 2>&1
"${NTFS_RUNTIME}/bin/ntfs-3g.probe" --readwrite "${PLAIN_IMAGE}"
log "RESULT=SYNTHETIC_CLEAN_NTFS_FIXTURE_PREPARED"

"${ENCRYPT_BIN}" "${PLAIN_IMAGE}" "${CIPHER_IMAGE}" "${KEY_HEX}" \
  | tee -a "${REPORT_FILE}"
CIPHER_SHA_BEFORE="$(/usr/bin/shasum -a 256 "${CIPHER_IMAGE}" | /usr/bin/awk '{print $1}')"
log "CIPHER_SHA256_BEFORE=${CIPHER_SHA_BEFORE}"

start_bridge
log "RESULT=EDP_CRYPTO_READWRITE_FUSE_READY"
start_ntfs
log "RESULT=BUNDLED_NTFS3G_IMAGE_FSKIT_MOUNTED_READWRITE"

PROOF_DIR="${NTFS_MOUNT}/EDP-RW"
PROOF_PATH="${PROOF_DIR}/proof.bin"
TEMP_PATH="${NTFS_MOUNT}/delete-me.tmp"
log "STEP=NTFS_ROOT_IO_BEGIN"
diagnose_ntfs_state "BEFORE_MKDIR"
/bin/mkdir "${PROOF_DIR}"
log "STEP=NTFS_MKDIR_OK"
diagnose_ntfs_state "AFTER_MKDIR"
sleep 0.1
diagnose_ntfs_state "AFTER_MKDIR_100MS"
ROOT_CREATE_PATH="${NTFS_MOUNT}/root-create.tmp"
NESTED_CREATE_PATH="${PROOF_DIR}/nested-create.tmp"
set +e
/usr/bin/touch "${ROOT_CREATE_PATH}"
ROOT_CREATE_RC=$?
/usr/bin/touch "${NESTED_CREATE_PATH}"
NESTED_CREATE_RC=$?
set -e
log "NTFS_CREATE_PROBE root_rc=${ROOT_CREATE_RC} nested_rc=${NESTED_CREATE_RC}"
if (( ROOT_CREATE_RC == 0 )); then /bin/rm -f "${ROOT_CREATE_PATH}"; fi
if (( NESTED_CREATE_RC == 0 )); then /bin/rm -f "${NESTED_CREATE_PATH}"; fi
diagnose_ntfs_state "AFTER_CREATE_PROBE"
[[ ${ROOT_CREATE_RC} -eq 0 && ${NESTED_CREATE_RC} -eq 0 ]]
log "STEP=NTFS_FILE_CREATE_BEGIN"
python3 - "${PROOF_PATH}" "${TEMP_PATH}" <<'PY'
import os
import sys
proof, temp = sys.argv[1:]
with open(proof, "wb", buffering=0) as handle:
    for block in range(1024):
        handle.write(bytes(((block * 23 + index * 41 + 7) & 0xff) for index in range(4096)))
with open(proof, "r+b", buffering=0) as handle:
    handle.seek(12345)
    handle.write(b"EDP-NTFS3G-RANDOM-WRITE")
    handle.seek(-4096, os.SEEK_END)
    handle.write(bytes((index * 17 + 3) & 0xff for index in range(4096)))
with open(temp, "wb") as handle:
    handle.write(b"must disappear before remount")
os.unlink(temp)
PY
log "STEP=NTFS_FILE_CREATE_RANDOMWRITE_DELETE_OK"
diagnose_ntfs_state "AFTER_FILE_IO"
/bin/mv "${PROOF_PATH}" "${PROOF_DIR}/proof-renamed.bin"
PROOF_PATH="${PROOF_DIR}/proof-renamed.bin"
/bin/sync
EXPECTED_SHA="$(/usr/bin/shasum -a 256 "${PROOF_PATH}" | /usr/bin/awk '{print $1}')"
log "EXPECTED_NTFS_PAYLOAD_SHA256=${EXPECTED_SHA}"
log "RESULT=BUNDLED_NTFS3G_FILE_CREATE_RANDOMWRITE_RENAME_DELETE_OK"

unmount_ntfs
DYLD_LIBRARY_PATH="${NTFS_RUNTIME}/lib" \
  "${NTFS_RUNTIME}/bin/ntfs-3g.probe" --readwrite "${BRIDGE_MOUNT}/volume.raw"
unmount_bridge
CIPHER_SHA_AFTER="$(/usr/bin/shasum -a 256 "${CIPHER_IMAGE}" | /usr/bin/awk '{print $1}')"
log "CIPHER_SHA256_AFTER=${CIPHER_SHA_AFTER}"
[[ "${CIPHER_SHA_AFTER}" != "${CIPHER_SHA_BEFORE}" ]]
log "RESULT=EDP_ENCRYPTED_NTFS_WRITE_CHANGED_CIPHERTEXT"

start_bridge
start_ntfs
ACTUAL_SHA="$(/usr/bin/shasum -a 256 "${PROOF_PATH}" | /usr/bin/awk '{print $1}')"
log "ACTUAL_NTFS_PAYLOAD_SHA256=${ACTUAL_SHA}"
[[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]]
[[ ! -e "${TEMP_PATH}" ]]
log "RESULT=EDP_NTFS3G_WRITE_SURVIVES_FULL_REMOUNT"

unmount_ntfs
DYLD_LIBRARY_PATH="${NTFS_RUNTIME}/lib" \
  "${NTFS_RUNTIME}/bin/ntfs-3g.probe" --readwrite "${BRIDGE_MOUNT}/volume.raw"
unmount_bridge

cleanup
if is_mounted "${NTFS_MOUNT}" || is_mounted "${BRIDGE_MOUNT}"; then
  log "ERROR=NTFS3G_E2E_TEARDOWN_FAILED"
  exit 1
fi
trap - EXIT INT TERM
log "RESULT=EDP_CRYPTO_NTFS3G_IMAGE_READWRITE_E2E_OK"
