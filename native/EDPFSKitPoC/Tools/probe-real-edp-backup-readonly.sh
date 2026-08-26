#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RAW_DEVICE="${EDP_RAW_DEVICE:-/dev/rdisk5}"
DEVICE_SIZE="${EDP_DEVICE_SIZE:-124736503808}"
DEVICE_VID="${EDP_DEVICE_VID:-21c4}"
DEVICE_PID="${EDP_DEVICE_PID:-0cd1}"
PARTITION_TYPE="${EDP_PARTITION_TYPE:-2}"
RESTORED_IMAGE="${EDP_RESTORED_IMAGE:-${ROOT}/artifacts/a6-real-disk5/disk5-restored.raw}"
WORK="${EDP_VERIFY_WORK:-${ROOT}/artifacts/a6-real-disk5/ntfs-readonly-verify}"
RUNTIME="/Library/Application Support/EDP USB Vault"
BRIDGE_MOUNT="${WORK}/bridge"
NTFS_MOUNT="${WORK}/ntfs"
FUSE_PID=""
NTFS_PID=""

mkdir -p "${WORK}" "${BRIDGE_MOUNT}" "${NTFS_MOUNT}"

is_mounted() { /sbin/mount | grep -F " on $1 " >/dev/null 2>&1; }
stop_current() {
  if is_mounted "${NTFS_MOUNT}"; then /sbin/umount "${NTFS_MOUNT}" >/dev/null 2>&1 || true; fi
  if [[ -n "${NTFS_PID}" ]]; then kill -TERM "${NTFS_PID}" >/dev/null 2>&1 || true; wait "${NTFS_PID}" >/dev/null 2>&1 || true; fi
  NTFS_PID=""
  if is_mounted "${BRIDGE_MOUNT}"; then /sbin/umount "${BRIDGE_MOUNT}" >/dev/null 2>&1 || true; fi
  if [[ -n "${FUSE_PID}" ]]; then kill -TERM "${FUSE_PID}" >/dev/null 2>&1 || true; wait "${FUSE_PID}" >/dev/null 2>&1 || true; fi
  FUSE_PID=""
}
trap stop_current EXIT INT TERM

TOOLS="${WORK}/tools"
mkdir -p "${TOOLS}"
CORE=(
  "${ROOT}/native/EDPFSKitPoC/Extension/EDPRawIO.swift"
  "${ROOT}/native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift"
  "${ROOT}/native/EDPFSKitPoC/Extension/EDPCrypto.swift"
  "${ROOT}/native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift"
  "${ROOT}/native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift"
  "${ROOT}/native/EDPFSKitPoC/Extension/EDPBlockDevice.swift"
  "${ROOT}/native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift"
)
xcrun swiftc -O -emit-library -module-name EDPReadOnlyBridge \
  "${CORE[@]}" "${ROOT}/native/EDPFSKitPoC/Tools/EDPReadOnlyBlockCBridge.swift" \
  -o "${TOOLS}/libEDPReadOnlyBridge.dylib"
FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
# shellcheck disable=SC2086
cc -O2 -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} \
  "${ROOT}/native/EDPFSKitPoC/Tools/EDPReadOnlyFuseBridge.c" ${FUSE_LIBS} \
  -framework Security "${TOOLS}/libEDPReadOnlyBridge.dylib" \
  -Wl,-rpath,"${TOOLS}" -o "${TOOLS}/edp-readonly-fuse"
xcrun swiftc -parse-as-library -O -framework CryptoKit \
  "${ROOT}/native/EDPFSKitPoC/Tools/EDPFilesystemManifest.swift" \
  -o "${TOOLS}/edp-filesystem-manifest"

read -r -s -p 'EDP password (kept in memory only): ' EDP_PASSWORD
printf '\n'
[[ -n "${EDP_PASSWORD}" ]]

run_one() {
  local name="$1" source="$2" mode="$3"
  local bridge_log="${WORK}/${name}-bridge.log"
  local ntfs_log="${WORK}/${name}-ntfs.log"
  local manifest="${WORK}/${name}-files.json"
  stop_current
  : >"${bridge_log}"
  : >"${ntfs_log}"
  exec 3< <(printf '%s' "${EDP_PASSWORD}")
  if [[ "${mode}" == --device-authorize ]]; then
    # Authorization Services must run in the foreground GUI terminal session.
    # libfuse daemonizes only after authopen has returned the O_RDONLY fd.
    DYLD_LIBRARY_PATH="${TOOLS}" "${TOOLS}/edp-readonly-fuse" \
      "${mode}" "${source}" "${DEVICE_VID}" "${DEVICE_PID}" "${DEVICE_SIZE}" \
      "${PARTITION_TYPE}" 3 "${BRIDGE_MOUNT}" >"${bridge_log}" 2>&1 3<&3
    FUSE_PID=""
  else
    DYLD_LIBRARY_PATH="${TOOLS}" "${TOOLS}/edp-readonly-fuse" \
      "${mode}" "${source}" "${DEVICE_VID}" "${DEVICE_PID}" "${DEVICE_SIZE}" \
      "${PARTITION_TYPE}" 3 "${BRIDGE_MOUNT}" >"${bridge_log}" 2>&1 3<&3 &
    FUSE_PID=$!
  fi
  exec 3<&-
  for _ in $(seq 1 100); do
    [[ -r "${BRIDGE_MOUNT}/volume.raw" ]] && break
    [[ -z "${FUSE_PID}" ]] || kill -0 "${FUSE_PID}" >/dev/null 2>&1 || break
    sleep 0.2
  done
  [[ -r "${BRIDGE_MOUNT}/volume.raw" ]] || { cat "${bridge_log}" >&2; return 1; }
  local source_volume="${BRIDGE_MOUNT}/volume.raw"
  set +e
  DYLD_LIBRARY_PATH="${RUNTIME}/lib" "${RUNTIME}/bin/ntfs-3g.probe" --readwrite "${source_volume}"
  local rw_probe=$?
  set -e
  [[ ${rw_probe} -eq 0 ]] || { echo "ERROR=${name}_RW_PROBE_REFUSED:${rw_probe}" >&2; return 1; }
  DYLD_LIBRARY_PATH="${RUNTIME}/lib" "${RUNTIME}/bin/ntfs-3g.probe" --readonly "${source_volume}"
  local label
  label="$(DYLD_LIBRARY_PATH="${RUNTIME}/lib" "${RUNTIME}/bin/ntfslabel" "${source_volume}" | tr -d '\r\n')"
  DYLD_LIBRARY_PATH="${RUNTIME}/lib" "${RUNTIME}/bin/ntfs-3g" \
    -o backend=fskit -o no_detach -o ro -o norecover -o windows_names \
    -o streams_interface=openxattr -o noatime -o big_writes \
    -o "uid=$(id -u)" -o "gid=$(id -g)" -o "volname=${label}" \
    "${source_volume}" "${NTFS_MOUNT}" >"${ntfs_log}" 2>&1 &
  NTFS_PID=$!
  for _ in $(seq 1 100); do
    is_mounted "${NTFS_MOUNT}" && break
    kill -0 "${NTFS_PID}" >/dev/null 2>&1 || break
    sleep 0.2
  done
  is_mounted "${NTFS_MOUNT}" || { cat "${ntfs_log}" >&2; return 1; }
  /sbin/mount | grep -F " on ${NTFS_MOUNT} " | tee "${WORK}/${name}-mount.txt"
  "${TOOLS}/edp-filesystem-manifest" "${NTFS_MOUNT}" "${source_volume}" "${label}" "${manifest}" \
    | tee "${WORK}/${name}-manifest.log"
  echo "${name}_RW_PROBE=${rw_probe}"
  echo "${name}_VOLUME_LABEL=${label}"
  stop_current
}

run_one physical "${RAW_DEVICE}" --device-authorize
run_one restored "${RESTORED_IMAGE}" --device
unset EDP_PASSWORD

cmp -s "${WORK}/physical-files.json" "${WORK}/restored-files.json"
MANIFEST_SHA="$(shasum -a 256 "${WORK}/physical-files.json" | awk '{print $1}')"
echo "MATCHED_FILESYSTEM_MANIFEST_SHA256=${MANIFEST_SHA}"
echo 'RESULT=REAL_EDP_RESTORED_NTFS_FILES_MATCH_OK'
trap - EXIT INT TERM
