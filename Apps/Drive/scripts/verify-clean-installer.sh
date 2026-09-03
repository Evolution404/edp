#!/bin/bash
set -euo pipefail

PACKAGE="${1:?usage: verify-clean-installer.sh <combined.pkg>}"
REQUIRE_RELEASE_SIGNING="${EDP_REQUIRE_RELEASE_SIGNING:-0}"
EXPECTED_RELEASE_CERT_ROOT_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"
[[ "${REQUIRE_RELEASE_SIGNING}" == "0" || "${REQUIRE_RELEASE_SIGNING}" == "1" ]] || {
  echo "EDP_REQUIRE_RELEASE_SIGNING must be 0 or 1" >&2
  exit 2
}
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
  com.edp.drive.runtime; do
  /usr/bin/grep -F "id=\"${identifier}\"" "${EXPANDED}/Distribution" >/dev/null
done

PAYLOAD="${EXPANDED}/ZZ-EDP-Drive.pkg/Payload"
ROOT="${PAYLOAD}/Library/Application Support/EDP Drive"
APP="${PAYLOAD}/Applications/EDP Drive.app"
SERVICE="${APP}/Contents/Library/LaunchServices/edp-drive-service"
PACKAGE_INFO="${EXPANDED}/ZZ-EDP-Drive.pkg/PackageInfo"
PREINSTALL="${EXPANDED}/ZZ-EDP-Drive.pkg/Scripts/preinstall"
DAEMON_PLIST="${APP}/Contents/Library/LaunchDaemons/com.edp.drive.service.plist"
LEGACY_DAEMON_PLIST="${PAYLOAD}/Library/LaunchDaemons/com.edp.drive.service.plist"
for path in \
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
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")" == "com.edp.drive" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${APP}/Contents/Info.plist")" == "EDPDrive.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "${APP}/Contents/Info.plist")" == "Copyright © 2026 EDP" ]]
[[ -s "${APP}/Contents/Resources/EDPDrive.icns" ]]
/usr/bin/file "${APP}/Contents/Resources/EDPDrive.icns" | /usr/bin/grep -F 'Mac OS X icon' >/dev/null
[[ -x "${SERVICE}" ]]
/usr/bin/codesign --verify --strict "${SERVICE}"
/usr/bin/codesign -dv --verbose=4 "${SERVICE}" 2>&1 \
  | /usr/bin/grep -F 'Identifier=com.edp.drive.service' >/dev/null
if [[ "${REQUIRE_RELEASE_SIGNING}" == "1" ]]; then
  APP_REQUIREMENT="$(/usr/bin/codesign -dr - "${APP}" 2>&1)"
  SERVICE_REQUIREMENT="$(/usr/bin/codesign -dr - "${SERVICE}" 2>&1)"
  EXPECTED_REQUIREMENT="certificate root = H\"${EXPECTED_RELEASE_CERT_ROOT_SHA1}\""
  /usr/bin/grep -Fq "${EXPECTED_REQUIREMENT}" <<<"${APP_REQUIREMENT}" || {
    echo "release App is not signed by the pinned EDP Project Code Signing certificate" >&2
    exit 5
  }
  /usr/bin/grep -Fq "${EXPECTED_REQUIREMENT}" <<<"${SERVICE_REQUIREMENT}" || {
    echo "release service is not signed by the pinned EDP Project Code Signing certificate" >&2
    exit 5
  }
  echo "RESULT=STABLE_SELF_SIGNED_RELEASE_IDENTITY"
fi
APP_COUNT="$(/usr/bin/find "${PAYLOAD}/Applications" -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "${APP_COUNT}" == "1" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP USB Vault.app" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP USB Vault Raw Access.app" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP Drive Service.app" ]]
[[ ! -e "${PAYLOAD}/Applications/EDP Drive Raw Access.app" ]]
/usr/bin/grep -F '<relocate/>' "${PACKAGE_INFO}" >/dev/null
if /usr/bin/grep -A 4 '<relocate>' "${PACKAGE_INFO}" \
  | /usr/bin/grep -F 'com.edp.drive' >/dev/null; then
  echo "EDP Drive must not be relocatable; FDA requires its fixed /Applications path" >&2
  exit 5
fi
echo "RESULT=SINGLE_DRIVE_APP_WITH_EMBEDDED_SERVICE"
echo "RESULT=DRIVE_APP_FIXED_INSTALL_PATH"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${APP}/Contents/Info.plist")" == "26.0" ]]
SERVICE_MODE="$(/usr/libexec/PlistBuddy -c 'Print :EDPServiceMode' "${APP}/Contents/Info.plist")"
[[ -x "${SERVICE}" ]]
if /usr/libexec/PlistBuddy -c 'Print :KeepAlive' "${DAEMON_PLIST}" >/dev/null 2>&1 \
   || /usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "${DAEMON_PLIST}" >/dev/null 2>&1; then
  echo "embedded service plist must be on-demand and user-stoppable" >&2
  exit 5
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ThrottleInterval' "${DAEMON_PLIST}")" == "1" ]]
case "${SERVICE_MODE}" in
  smappservice)
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "${DAEMON_PLIST}")" == "com.edp.drive.service" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.edp.drive.service' "${DAEMON_PLIST}")" == "true" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "${DAEMON_PLIST}")" == "Contents/Library/LaunchServices/edp-drive-service" ]]
    [[ ! -e "${LEGACY_DAEMON_PLIST}" ]]
    /usr/bin/codesign -dv --verbose=4 \
      "${SERVICE}" 2>&1 \
      | /usr/bin/grep -F 'Identifier=com.edp.drive.service' >/dev/null
    echo "RESULT=SMAPPSERVICE_DAEMON_EMBEDDED"
    ;;
  legacy)
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "${LEGACY_DAEMON_PLIST}")" == "com.edp.drive.service" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.edp.drive.service' "${LEGACY_DAEMON_PLIST}")" == "true" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${LEGACY_DAEMON_PLIST}")" == "/Applications/EDP Drive.app/Contents/Library/LaunchServices/edp-drive-service" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:EDP_RUNTIME_BIN_ROOT' "${LEGACY_DAEMON_PLIST}")" == "/Library/Application Support/EDP Drive/bin" ]]
    [[ -e "${DAEMON_PLIST}" ]]
    if /usr/libexec/PlistBuddy -c 'Print :KeepAlive' "${LEGACY_DAEMON_PLIST}" >/dev/null 2>&1 \
       || /usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "${LEGACY_DAEMON_PLIST}" >/dev/null 2>&1; then
      echo "installer-managed service plist must be on-demand and user-stoppable" >&2
      exit 5
    fi
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ThrottleInterval' "${LEGACY_DAEMON_PLIST}")" == "1" ]]
    echo "RESULT=LEGACY_XPC_ROOT_SERVICE_PACKAGED"
    echo "RESULT=LEGACY_XPC_DAEMON_PACKAGED"
    ;;
  *)
    echo "unexpected EDPServiceMode: ${SERVICE_MODE}" >&2
    exit 4
    ;;
esac
echo "RESULT=USER_STOPPABLE_ON_DEMAND_SERVICE_PLIST"
echo "RESULT=SERVICE_RESTART_THROTTLE_1S"
echo "SERVICE_MODE=${SERVICE_MODE}"
if [[ "${REQUIRE_RELEASE_SIGNING}" == "1" ]]; then
  [[ "${SERVICE_MODE}" == "legacy" ]] || {
    echo "self-signed release requires installer-managed legacy service mode" >&2
    exit 5
  }
  echo "RESULT=SELF_SIGNED_RELEASE_SERVICE_MODE_OK"
fi
echo "RESULT=NATIVE_SWIFTUI_XPC_APP_PACKAGED"
echo "RESULT=DRIVE_APP_ICON_PACKAGED"

[[ ! -e "${ROOT}/test-tools" ]]
[[ ! -e "${ROOT}/bin/ntfs-3g" ]]
[[ ! -e "${ROOT}/bin/ntfs-3g.probe" ]]
[[ ! -e "${ROOT}/bin/ntfslabel" ]]
[[ ! -e "${ROOT}/lib/libntfs-3g.90.dylib" ]]
echo "RESULT=NTFS3G_RUNTIME_ABSENT"

# Full Disk Access belongs to the single visible EDP Drive App identity. The
# privileged service never opens raw media directly; it spawns the same signed
# App executable in hidden root broker mode and receives the validated fd over
# SCM_RIGHTS. The foreground App never creates AuthorizationExternalForm/sys.openfile rights.
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
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F -- '--raw-fd-broker' >/dev/null
/usr/bin/nm "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F '_edp_raw_fd_broker_run_child' >/dev/null
/usr/bin/nm "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F '_edp_open_validated_raw_device' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F '/dev/rdisk' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F 'idVendor' >/dev/null
/usr/bin/strings "${APP}/Contents/MacOS/EDP Drive" \
  | /usr/bin/grep -F 'idProduct' >/dev/null
/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F 'single EDP Drive Full Disk Access identity broker + retained raw fd + inherited transport fd' >/dev/null
/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F 'EDP_RAW_LEASE_METADATA_REFUSED' >/dev/null
/usr/bin/nm "${SERVICE}" \
  | /usr/bin/grep -F '_edp_raw_fd_broker_spawn' >/dev/null
/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F '/Applications/EDP Drive.app/Contents/MacOS/EDP Drive' >/dev/null
/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F 'com.edp.drive.service:running' >/dev/null
/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F 'one or more EDP sessions could not be safely unmounted' >/dev/null
/usr/bin/nm -u "${SERVICE}" \
  | /usr/bin/grep -F '_posix_spawn' >/dev/null
/usr/bin/codesign -dv --verbose=4 "${SERVICE}" 2>&1 \
  | /usr/bin/grep -F 'Identifier=com.edp.drive.service' >/dev/null
CONSOLE_EXEC="${ROOT}/bin/edp-console-exec"
/usr/bin/strings "${CONSOLE_EXEC}" | /usr/bin/grep -F 'EDP_CONSOLE_EXEC_INHERITED_RAW_METADATA_REFUSED' >/dev/null
/usr/bin/strings "${CONSOLE_EXEC}" | /usr/bin/grep -F 'edp-mfmount-local-readwrite' >/dev/null
if /usr/bin/strings "${CONSOLE_EXEC}" | /usr/bin/grep -F -- '--probe-raw-device' >/dev/null \
   || /usr/bin/strings "${CONSOLE_EXEC}" | /usr/bin/grep -F -- '--raw-device /dev/rdisk' >/dev/null; then
  echo "console transport launcher unexpectedly retains a direct raw-open mode" >&2
  exit 6
fi
if /usr/bin/strings "${CONSOLE_EXEC}" | /usr/bin/grep -F 'authopen' >/dev/null; then
  echo "console transport launcher unexpectedly contains authopen" >&2
  exit 6
fi
echo "RESULT=FULL_DISK_ACCESS_SINGLE_APP_RAW_FD3_TRANSPORT_PATH_ENFORCED"

/usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F 'NTFS (read-only; Finder erasable)' >/dev/null
if /usr/bin/strings "${SERVICE}" \
  | /usr/bin/grep -F -- '--device-auth-readonly' >/dev/null; then
  echo "production daemon unexpectedly references read-only encrypted bridge mode" >&2
  exit 6
fi
echo "RESULT=PRODUCTION_APPLE_NTFS_POLICY_ENFORCED"

"${SERVICE}" help >/dev/null
[[ ! -e "${ROOT}/bin/edp-vaultctl" ]]
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
