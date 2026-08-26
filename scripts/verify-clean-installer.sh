#!/bin/bash
set -euo pipefail

PACKAGE="${1:?usage: verify-clean-installer.sh <combined.pkg>}"
[[ -f "${PACKAGE}" ]] || {
  echo "package not found: ${PACKAGE}" >&2
  exit 2
}

VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-installer-verify.XXXXXX")"
cleanup() {
  rm -rf "${VERIFY_ROOT}"
}
trap cleanup EXIT INT TERM

/usr/sbin/pkgutil --expand-full "${PACKAGE}" "${VERIFY_ROOT}/expanded"
EXPANDED="${VERIFY_ROOT}/expanded"

for identifier in \
  io.macfuse.installer.components.core \
  io.macfuse.installer.components.preferencepane \
  com.edp.usbvault.runtime; do
  /usr/bin/grep -F "id=\"${identifier}\"" "${EXPANDED}/Distribution" >/dev/null
done

PAYLOAD="${EXPANDED}/ZZ-EDP-USB-Vault.pkg/Payload"
ROOT="${PAYLOAD}/Library/Application Support/EDP USB Vault"
APP="${PAYLOAD}/Applications/EDP USB Vault.app"
DAEMON_PLIST="${APP}/Contents/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
LEGACY_DAEMON_PLIST="${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
for path in \
  "bin/edp-vaultctl" \
  "bin/edp-readwrite-fuse" \
  "bin/libEDPReadWriteBridge.dylib" \
  "bin/diskimages2-attach" \
  "bin/ntfs-3g" \
  "bin/ntfs-3g.probe" \
  "bin/ntfslabel" \
  "lib/libntfs-3g.90.dylib" \
  "licenses/macfuse/LICENSE.txt" \
  "licenses/ntfs-3g/COPYING" \
  "source/ntfs-3g_ntfsprogs-2026.7.7.tgz"; do
  [[ -e "${ROOT}/${path}" ]] || {
    echo "required payload path missing: ${path}" >&2
    exit 3
  }
done

for item in "${ROOT}/bin/"* "${ROOT}/lib/"*; do
  /usr/bin/codesign --verify --strict "${item}"
done

[[ -x "${APP}/Contents/MacOS/EDP USB Vault" ]]
/usr/bin/codesign --verify --strict "${APP}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")" == "com.edp.usbvault.app" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${APP}/Contents/Info.plist")" == "26.0" ]]
SERVICE_MODE="$(/usr/libexec/PlistBuddy -c 'Print :EDPServiceMode' "${APP}/Contents/Info.plist")"
[[ -x "${APP}/Contents/Library/LaunchServices/edp-usbvaultd" ]]
case "${SERVICE_MODE}" in
  smappservice)
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.edp.usbvault.xpc' "${DAEMON_PLIST}")" == "true" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "${DAEMON_PLIST}")" == "Contents/Library/LaunchServices/edp-usbvaultd" ]]
    [[ ! -e "${LEGACY_DAEMON_PLIST}" ]]
    echo "RESULT=SMAPPSERVICE_DAEMON_EMBEDDED"
    ;;
  legacy)
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.edp.usbvault.xpc' "${LEGACY_DAEMON_PLIST}")" == "true" ]]
    [[ ! -e "${DAEMON_PLIST}" ]]
    echo "RESULT=LEGACY_XPC_DAEMON_PACKAGED"
    ;;
  *)
    echo "unexpected EDPServiceMode: ${SERVICE_MODE}" >&2
    exit 4
    ;;
esac
echo "SERVICE_MODE=${SERVICE_MODE}"
echo "RESULT=NATIVE_SWIFTUI_XPC_APP_PACKAGED"

[[ ! -e "${ROOT}/test-tools" ]]
[[ ! -e "${ROOT}/bin/mkntfs" ]]
[[ ! -e "${ROOT}/bin/ntfscp" ]]
echo "RESULT=PRODUCTION_NTFS_RUNTIME_CONTAINS_NO_FIXTURE_TOOLS"

/usr/bin/otool -L "${ROOT}/bin/edp-readwrite-fuse" \
  | /usr/bin/grep -F '@rpath/libEDPReadWriteBridge.dylib' >/dev/null
/usr/bin/otool -L "${ROOT}/bin/ntfs-3g" \
  | /usr/bin/grep -F '@loader_path/../lib/libntfs-3g.90.dylib' >/dev/null
/usr/bin/otool -L "${ROOT}/bin/ntfs-3g" \
  | /usr/bin/grep -F '/usr/local/lib/libfuse.2.dylib' >/dev/null

printf '%s  %s\n' \
  d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab \
  "${ROOT}/source/ntfs-3g_ntfsprogs-2026.7.7.tgz" \
  | /usr/bin/shasum -a 256 -c -

"${ROOT}/bin/edp-vaultctl" help >/dev/null
"${ROOT}/bin/ntfs-3g.probe" --help >/dev/null

if [[ "${EDP_INSTALLER_SYSTEM_TESTS:-0}" == "1" ]]; then
  IMAGE="${VERIFY_ROOT}/raw.img"
  /usr/bin/truncate -s 16777216 "${IMAGE}"
  ATTACH_OUTPUT="$("${ROOT}/bin/diskimages2-attach" --writable-noautomount "${IMAGE}")"
  BSD_NAME="$(printf '%s\n' "${ATTACH_OUTPUT}" | /usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' | /usr/bin/tail -1)"
  [[ -n "${BSD_NAME}" && -b "/dev/${BSD_NAME}" ]]
  /usr/sbin/diskutil info "${BSD_NAME}" | /usr/bin/grep -Eq \
    'Media Read-Only:[[:space:]]+No'
  /usr/sbin/diskutil eject "${BSD_NAME}" >/dev/null
fi

echo "RESULT=EDP_CLEAN_INSTALLER_VERIFIED"
