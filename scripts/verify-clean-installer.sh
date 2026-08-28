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
RAW_ACCESS_APP="${PAYLOAD}/Applications/EDP USB Vault Raw Access.app"
PACKAGE_INFO="${EXPANDED}/ZZ-EDP-USB-Vault.pkg/PackageInfo"
DAEMON_PLIST="${APP}/Contents/Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist"
LEGACY_DAEMON_PLIST="${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
for path in \
  "bin/edp-vaultctl" \
  "bin/edp-console-exec" \
  "bin/edp-fuset-readwrite" \
  "bin/edp-mfmount-local-readwrite" \
  "bin/edp-raw-metadata" \
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
[[ -x "${RAW_ACCESS_APP}/Contents/MacOS/edp-console-exec" ]]
/usr/bin/codesign --verify --strict "${RAW_ACCESS_APP}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${RAW_ACCESS_APP}/Contents/Info.plist")" == "com.edp.usbvault.rawaccess" ]]
/usr/bin/codesign -dv --verbose=4 "${RAW_ACCESS_APP}" 2>&1 \
  | /usr/bin/grep -F 'Identifier=com.edp.usbvault.rawaccess' >/dev/null
/usr/bin/grep -F '<relocate/>' "${PACKAGE_INFO}" >/dev/null
if /usr/bin/grep -A 4 '<relocate>' "${PACKAGE_INFO}" \
  | /usr/bin/grep -F 'com.edp.usbvault.rawaccess' >/dev/null; then
  echo "Raw Access helper must not be relocatable; FDA requires its fixed /Applications path" >&2
  exit 5
fi
echo "RESULT=RAW_ACCESS_HELPER_FIXED_INSTALL_PATH"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${APP}/Contents/Info.plist")" == "26.0" ]]
SERVICE_MODE="$(/usr/libexec/PlistBuddy -c 'Print :EDPServiceMode' "${APP}/Contents/Info.plist")"
[[ -x "${APP}/Contents/Library/LaunchServices/edp-usbvaultd" ]]
case "${SERVICE_MODE}" in
  smappservice)
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.edp.usbvault.xpc' "${DAEMON_PLIST}")" == "true" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "${DAEMON_PLIST}")" == "Contents/Library/LaunchServices/edp-usbvaultd" ]]
    [[ ! -e "${LEGACY_DAEMON_PLIST}" ]]
    /usr/bin/codesign -dv --verbose=4 \
      "${APP}/Contents/Library/LaunchServices/edp-usbvaultd" 2>&1 \
      | /usr/bin/grep -F 'Identifier=com.edp.usbvault.mountd.v2' >/dev/null
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

# The stable Raw Access helper is the only writable raw-device broker. The
# foreground App never creates AuthorizationExternalForm/sys.openfile rights.
if /usr/bin/nm -u "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F '_AuthorizationCopyRights' >/dev/null; then
  echo "foreground App unexpectedly contains Authorization Services raw access" >&2
  exit 6
fi
if /usr/bin/nm -u "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F '_AuthorizationMakeExternalForm' >/dev/null; then
  echo "foreground App unexpectedly externalizes AuthorizationRef" >&2
  exit 6
fi
/usr/bin/strings "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F 'Privacy_AllFiles' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F '/Applications/EDP USB Vault Raw Access.app' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F 'macfuse-local.appex' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F 'io.macfuse.app.fsmodule.macfuse-local' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F 'group.com.apple.fskit.settings' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F 'fskit_agent' >/dev/null
echo "RESULT=CONSOLE_USER_MACFUSE_FSKIT_ENABLEMENT_PACKAGED"
if /usr/bin/strings "${APP}/Contents/MacOS/EDP USB Vault" \
  | /usr/bin/grep -F '/Applications/fuse-t.app' >/dev/null; then
  echo "production App unexpectedly gates mounting on FUSE-T" >&2
  exit 6
fi
/usr/bin/strings "${ROOT}/bin/edp-raw-metadata" \
  | /usr/bin/grep -F 'raw read-only open failed' >/dev/null
/usr/bin/strings "${ROOT}/bin/edp-raw-metadata" \
  | /usr/bin/grep -F 'privilege drop failed' >/dev/null
if /usr/bin/strings "${ROOT}/bin/edp-raw-metadata" | /usr/bin/grep -F 'authopen' >/dev/null; then
  echo "raw metadata helper unexpectedly contains authopen" >&2
  exit 6
fi
/usr/bin/strings "${ROOT}/bin/edp-vaultctl" \
  | /usr/bin/grep -F 'persistent Full Disk Access broker + inherited raw fd' >/dev/null
/usr/bin/strings "${ROOT}/bin/edp-vaultctl" \
  | /usr/bin/grep -F '/Applications/EDP USB Vault Raw Access.app/Contents/MacOS/edp-console-exec' >/dev/null
for BROKER in \
  "${ROOT}/bin/edp-console-exec" \
  "${RAW_ACCESS_APP}/Contents/MacOS/edp-console-exec"; do
  /usr/bin/strings "${BROKER}" | /usr/bin/grep -F 'EDP_RAW_BROKER_TARGET_REFUSED' >/dev/null
  /usr/bin/strings "${BROKER}" | /usr/bin/grep -F 'EDP_RAW_BROKER_METADATA_REFUSED' >/dev/null
  /usr/bin/strings "${BROKER}" | /usr/bin/grep -F 'EDP_RAW_BROKER_PROBE_OK' >/dev/null
  /usr/bin/strings "${BROKER}" | /usr/bin/grep -F 'idVendor' >/dev/null
  /usr/bin/strings "${BROKER}" | /usr/bin/grep -F 'idProduct' >/dev/null
  /usr/bin/strings "${BROKER}" | /usr/bin/grep -F '/dev/rdisk' >/dev/null
  /usr/bin/strings "${BROKER}" | /usr/bin/grep -F 'edp-mfmount-local-readwrite' >/dev/null
  if /usr/bin/strings "${BROKER}" | /usr/bin/grep -F 'authopen' >/dev/null; then
    echo "FDA raw broker unexpectedly contains authopen" >&2
    exit 6
  fi
  if /usr/bin/strings "${BROKER}" | /usr/bin/grep -F -- '--raw-device-auth' >/dev/null; then
    echo "FDA raw broker unexpectedly contains exact-path authorization mode" >&2
    exit 6
  fi
done
echo "RESULT=FULL_DISK_ACCESS_RAW_FD3_TRANSPORT_PATH_ENFORCED"

/usr/bin/strings "${ROOT}/bin/edp-vaultctl" \
  | /usr/bin/grep -F 'NTFS (read-only; Finder erasable)' >/dev/null
if /usr/bin/strings "${ROOT}/bin/edp-vaultctl" \
  | /usr/bin/grep -F -- '--device-auth-readonly' >/dev/null; then
  echo "production daemon unexpectedly references read-only encrypted bridge mode" >&2
  exit 6
fi
echo "RESULT=PRODUCTION_APPLE_NTFS_POLICY_ENFORCED"

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
[[ ! -e "${ROOT}/bin/edp-readwrite-fuse" ]]
[[ ! -e "${ROOT}/bin/edp-raw-sparse" ]]
echo "RESULT=LEGACY_AUTHOPEN_RUNTIME_REMOVED"

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
