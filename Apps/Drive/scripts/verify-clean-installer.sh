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
APP="${PAYLOAD}/Applications/EDP Drive.app"
SERVICE="${APP}/Contents/Library/LaunchServices/edp-drive-service"
PACKAGE_INFO="${EXPANDED}/ZZ-EDP-USB-Vault.pkg/PackageInfo"
PREINSTALL="${EXPANDED}/ZZ-EDP-USB-Vault.pkg/Scripts/preinstall"
DAEMON_PLIST="${APP}/Contents/Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist"
LEGACY_DAEMON_PLIST="${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
for path in \
  "bin/edp-vaultctl" \
  "bin/edp-console-exec" \
  "bin/edp-mfmount-local-readwrite" \
  "bin/edp-raw-metadata" \
  "bin/libEDPReadWriteBridge.dylib" \
  "bin/diskimages2-attach" \
  "licenses/macfuse/LICENSE.txt"; do
  [[ -e "${ROOT}/${path}" ]] || {
    echo "required payload path missing: ${path}" >&2
    exit 3
  }
done

TRANSPORT_BINARIES="$(/usr/bin/find "${ROOT}/bin" -maxdepth 1 -type f -name 'edp-*readwrite*' -print | /usr/bin/sort)"
[[ "${TRANSPORT_BINARIES}" == "${ROOT}/bin/edp-mfmount-local-readwrite" ]] || {
  echo "unexpected EDP transport runtime set: ${TRANSPORT_BINARIES}" >&2
  exit 3
}
echo "RESULT=MACFUSE_ONLY_TRANSPORT_PACKAGED"

for item in "${ROOT}/bin/"*; do
  /usr/bin/codesign --verify --strict "${item}"
done

[[ -x "${APP}/Contents/MacOS/EDP Drive" ]]
/usr/bin/codesign --verify --strict "${APP}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")" == "com.edp.usbvault.app" ]]
[[ -x "${SERVICE}" ]]
/usr/bin/codesign --verify --strict "${SERVICE}"
/usr/bin/codesign -dv --verbose=4 "${SERVICE}" 2>&1 \
  | /usr/bin/grep -F 'Identifier=com.edp.usbvault.mountd.v2' >/dev/null
APP_COUNT="$(/usr/bin/find "${PAYLOAD}/Applications" -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "${APP_COUNT}" == "1" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP USB Vault.app" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP USB Vault Raw Access.app" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP Drive Service.app" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP Drive Raw Access.app" ]]
/usr/bin/grep -F '<relocate/>' "${PACKAGE_INFO}" >/dev/null
if /usr/bin/grep -A 4 '<relocate>' "${PACKAGE_INFO}" \
  | /usr/bin/grep -F 'com.edp.usbvault.app' >/dev/null; then
  echo "EDP Drive must not be relocatable; FDA requires its fixed /Applications path" >&2
  exit 5
fi
echo "RESULT=SINGLE_DRIVE_APP_WITH_EMBEDDED_SERVICE"
echo "RESULT=DRIVE_APP_FIXED_INSTALL_PATH"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${APP}/Contents/Info.plist")" == "26.0" ]]
SERVICE_MODE="$(/usr/libexec/PlistBuddy -c 'Print :EDPServiceMode' "${APP}/Contents/Info.plist")"
[[ -x "${SERVICE}" ]]
case "${SERVICE_MODE}" in
  smappservice)
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.edp.usbvault.xpc' "${DAEMON_PLIST}")" == "true" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "${DAEMON_PLIST}")" == "Contents/Library/LaunchServices/edp-drive-service" ]]
    [[ ! -e "${LEGACY_DAEMON_PLIST}" ]]
    /usr/bin/codesign -dv --verbose=4 \
      "${SERVICE}" 2>&1 \
      | /usr/bin/grep -F 'Identifier=com.edp.usbvault.mountd.v2' >/dev/null
    echo "RESULT=SMAPPSERVICE_DAEMON_EMBEDDED"
    ;;
  legacy)
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.edp.usbvault.xpc' "${LEGACY_DAEMON_PLIST}")" == "true" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${LEGACY_DAEMON_PLIST}")" == "/Applications/EDP Drive.app/Contents/Library/LaunchServices/edp-drive-service" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:EDP_RUNTIME_BIN_ROOT' "${LEGACY_DAEMON_PLIST}")" == "/Library/Application Support/EDP USB Vault/bin" ]]
    [[ ! -e "${DAEMON_PLIST}" ]]
    echo "RESULT=LEGACY_FDA_DAEMON_PACKAGED"
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
[[ ! -e "${ROOT}/bin/ntfs-3g" ]]
[[ ! -e "${ROOT}/bin/ntfs-3g.probe" ]]
[[ ! -e "${ROOT}/bin/ntfslabel" ]]
[[ ! -e "${ROOT}/lib/libntfs-3g.90.dylib" ]]
echo "RESULT=NTFS3G_RUNTIME_ABSENT"

# The stable Raw Access helper is the only writable raw-device broker. The
# foreground App never creates AuthorizationExternalForm/sys.openfile rights.
if /usr/bin/nm -u "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F '_AuthorizationCopyRights' >/dev/null; then
  echo "foreground App unexpectedly contains Authorization Services raw access" >&2
  exit 6
fi
if /usr/bin/nm -u "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F '_AuthorizationMakeExternalForm' >/dev/null; then
  echo "foreground App unexpectedly externalizes AuthorizationRef" >&2
  exit 6
fi
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F 'Privacy_AllFiles' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F '/Applications/EDP Drive.app' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F 'macfuse-local.appex' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F 'io.macfuse.app.fsmodule.macfuse-local' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F 'group.com.apple.fskit.settings' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F 'fskit_agent' >/dev/null
echo "RESULT=CONSOLE_USER_MACFUSE_FSKIT_ENABLEMENT_PACKAGED"
/usr/bin/strings "${ROOT}/bin/edp-raw-metadata" \
  | /usr/bin/grep -F 'raw read-only open failed' >/dev/null
/usr/bin/strings "${ROOT}/bin/edp-raw-metadata" \
  | /usr/bin/grep -F 'privilege drop failed' >/dev/null
if /usr/bin/strings "${ROOT}/bin/edp-raw-metadata" | /usr/bin/grep -F 'authopen' >/dev/null; then
  echo "raw metadata helper unexpectedly contains authopen" >&2
  exit 6
fi
/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F 'persistent Full Disk Access daemon + retained raw fd + inherited transport fd' >/dev/null
/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F 'EDP_RAW_LEASE_METADATA_REFUSED' >/dev/null
/usr/bin/nm -u "${SERVICE}" \
  | /usr/bin/grep -F '_posix_spawn' >/dev/null
/usr/bin/codesign -dv --verbose=4 "${SERVICE}" 2>&1 \
  | /usr/bin/grep -F 'Identifier=com.edp.usbvault.mountd.v2' >/dev/null
for BROKER in \
  "${ROOT}/bin/edp-console-exec"; do
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

"${ROOT}/bin/edp-vaultctl" help >/dev/null
[[ ! -e "${ROOT}/bin/edp-readwrite-fuse" ]]
[[ ! -e "${ROOT}/bin/edp-raw-sparse" ]]
/usr/bin/grep -F 'edp-readwrite-fuse' "${PREINSTALL}" >/dev/null
/usr/bin/grep -F 'edp-raw-sparse' "${PREINSTALL}" >/dev/null
echo "RESULT=LEGACY_AUTHOPEN_RUNTIME_REMOVED"
echo "RESULT=LEGACY_AUTHOPEN_UPGRADE_CLEANUP_PACKAGED"

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
