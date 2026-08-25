#!/bin/bash
set -euo pipefail

BUNDLE_ID="com.edp.usbvault.fskit-poc.extension"
APP="${EDP_FSKIT_APP:-/Applications/EDPFSKitPoC.app}"
EXT="${APP}/Contents/Extensions/EDPFSKitExtension.appex"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAG_DIR="${EDP_RUNTIME_DIAG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edp-fskit-runtime.XXXXXX")}" 
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edp-fskit-work.XXXXXX")"
INSPECTOR="${WORK_DIR}/inspect-fskit"
RAW="${WORK_DIR}/probe.raw"
MOUNT_POINT="${WORK_DIR}/mnt"
DISK=""

mkdir -p "${DIAG_DIR}" "${MOUNT_POINT}"

cleanup() {
    if [[ -n "${DISK}" ]]; then
        diskutil unmount force "${MOUNT_POINT}" >/dev/null 2>&1 || true
        hdiutil detach "${DISK}" -force >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

fail() {
    echo "RESULT=FAILED:$1" >&2
    echo "DIAGNOSTICS=${DIAG_DIR}" >&2
    exit 1
}

echo "DIAGNOSTICS=${DIAG_DIR}"

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS_required"
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "${OS_MAJOR}" -ge 26 ]] || fail "macOS_26_or_newer_required"

test -d "${APP}" || fail "host_app_missing:${APP}"
test -d "${EXT}" || fail "embedded_extension_missing:${EXT}"
codesign --verify --deep --strict --verbose=2 "${APP}" \
    >"${DIAG_DIR}/codesign.out" 2>"${DIAG_DIR}/codesign.err" \
    || fail "codesign_verification_failed"

xcrun swiftc -framework FSKit "${SCRIPT_DIR}/InspectFSKit.swift" -o "${INSPECTOR}"
set +e
"${INSPECTOR}" >"${DIAG_DIR}/fsclient.txt" 2>&1
FSCLIENT_RC=$?
set -e
cat "${DIAG_DIR}/fsclient.txt"
echo "FSCLIENT_RC=${FSCLIENT_RC}"

if ! grep -Fq "FSKIT_MODULE_FOUND=${BUNDLE_ID}" "${DIAG_DIR}/fsclient.txt"; then
    fail "EDP_FSKIT_module_not_visible_to_FSClient"
fi
if ! grep -Fq 'FSKIT_MODULE_ENABLED=true' "${DIAG_DIR}/fsclient.txt"; then
    fail "EDP_FSKIT_module_not_enabled"
fi
echo 'RESULT=EDP_FSKIT_APPROVED_AND_ENABLED'

mkfile 16m "${RAW}"
ATTACH_OUT="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "${RAW}")"
printf '%s\n' "${ATTACH_OUT}" | tee "${DIAG_DIR}/hdiutil-attach.txt"
DISK="$(printf '%s\n' "${ATTACH_OUT}" | awk '/^\/dev\/disk/ {print $1; exit}')"
[[ -n "${DISK}" ]] || fail "raw_block_device_not_created"
test -b "${DISK}" || fail "attached_path_is_not_block_device:${DISK}"
echo "RESULT=RAW_BLOCK_DEVICE_READY:${DISK}"

LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
set +e
/sbin/mount -t edpvault "${DISK}" "${MOUNT_POINT}" \
    >"${DIAG_DIR}/mount.out" 2>"${DIAG_DIR}/mount.err"
MOUNT_RC=$?
set -e

echo "MOUNT_RC=${MOUNT_RC}"
cat "${DIAG_DIR}/mount.out" || true
cat "${DIAG_DIR}/mount.err" || true
sleep 2

log show --start "${LOG_START}" --style compact \
    --predicate 'subsystem == "com.edp.usbvault.fskit-poc.extension" OR eventMessage CONTAINS[c] "com.edp.usbvault.fskit-poc.extension" OR process == "fskitd"' \
    >"${DIAG_DIR}/runtime.log" 2>&1 || true
cat "${DIAG_DIR}/runtime.log" || true

BSD_NAME="$(basename "${DISK}")"
if ! grep -Fq "PROBE_BLOCK_DEVICE=${BSD_NAME}" "${DIAG_DIR}/runtime.log"; then
    fail "EDP_FSBlockDeviceResource_probe_not_observed:${BSD_NAME}"
fi

echo "RESULT=NATIVE_FSKIT_BLOCK_RESOURCE_DELIVERED:${BSD_NAME}"
echo "DIAGNOSTICS=${DIAG_DIR}"
