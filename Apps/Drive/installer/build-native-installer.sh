#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${REPO_ROOT}/scripts/prepare-shared-edp-core.sh"
VERSION="${EDP_VERSION:-0.6.0}"
OUTPUT_DIR="${1:-${REPO_ROOT}/artifacts}"
APP_SIGN_IDENTITY="${EDP_APP_SIGN_IDENTITY:--}"
APP_SIGN_KEYCHAIN="${EDP_APP_SIGN_KEYCHAIN:-}"
SERVICE_MODE="${EDP_SERVICE_MODE:-}"
SELF_SIGNED_DISTRIBUTION="${EDP_SELF_SIGNED_DISTRIBUTION:-0}"
if [[ -z "${SERVICE_MODE}" ]]; then
  if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
    SERVICE_MODE="legacy"
  else
    [[ "${APP_SIGN_IDENTITY}" == "-" ]] && SERVICE_MODE="legacy" || SERVICE_MODE="smappservice"
  fi
fi
[[ "${SERVICE_MODE}" == "legacy" || "${SERVICE_MODE}" == "smappservice" ]]
if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
  [[ "${SERVICE_MODE}" == "legacy" && "${APP_SIGN_IDENTITY}" != "-" ]] || {
    echo "self-signed distribution requires legacy service mode and a certificate-backed signing identity" >&2
    exit 2
  }
fi
if [[ -n "${APP_SIGN_KEYCHAIN}" && ! -f "${APP_SIGN_KEYCHAIN}" ]]; then
  echo "EDP_APP_SIGN_KEYCHAIN does not exist: ${APP_SIGN_KEYCHAIN}" >&2
  exit 2
fi

SIGNING_SEARCH_PREPARED=0
SIGNING_SEARCH_MODIFIED=0
ORIGINAL_USER_KEYCHAINS=()

prepare_signing_search_list() {
  [[ -n "${APP_SIGN_KEYCHAIN}" ]] || return 0
  [[ "${SIGNING_SEARCH_PREPARED}" == "0" ]] || return 0
  SIGNING_SEARCH_PREPARED=1

  local line path found=0
  while IFS= read -r line; do
    path="${line#"${line%%[![:space:]]*}"}"
    path="${path#\"}"
    path="${path%\"}"
    [[ -n "${path}" ]] || continue
    ORIGINAL_USER_KEYCHAINS+=("${path}")
    [[ "${path}" == "${APP_SIGN_KEYCHAIN}" ]] && found=1
  done < <(/usr/bin/security list-keychains -d user)

  if [[ "${found}" == "0" ]]; then
    /usr/bin/security list-keychains -d user -s \
      "${ORIGINAL_USER_KEYCHAINS[@]}" "${APP_SIGN_KEYCHAIN}"
    SIGNING_SEARCH_MODIFIED=1
  fi
}

restore_signing_search_list() {
  [[ "${SIGNING_SEARCH_MODIFIED}" == "1" ]] || return 0
  if (( ${#ORIGINAL_USER_KEYCHAINS[@]} > 0 )); then
    /usr/bin/security list-keychains -d user -s \
      "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  else
    /usr/bin/security list-keychains -d user -s >/dev/null 2>&1 || true
  fi
  SIGNING_SEARCH_MODIFIED=0
}

sign_app_code() {
  prepare_signing_search_list
  local args=(/usr/bin/codesign --force --sign "${APP_SIGN_IDENTITY}")
  if [[ -n "${APP_SIGN_KEYCHAIN}" ]]; then
    args+=(--keychain "${APP_SIGN_KEYCHAIN}")
  fi
  "${args[@]}" "$@"
}

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-native-installer.XXXXXX")"
cleanup() {
  restore_signing_search_list
  /bin/rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT INT TERM

RUNTIME_STAGE="${BUILD_ROOT}/runtime"
APP_STAGE="${BUILD_ROOT}/EDP Drive.app"
mkdir -p "${OUTPUT_DIR}" "${RUNTIME_STAGE}/bin" \
  "${APP_STAGE}/Contents/MacOS" \
  "${APP_STAGE}/Contents/Resources" \
  "${APP_STAGE}/Contents/Library/LaunchDaemons" \
  "${APP_STAGE}/Contents/Library/LaunchServices"

CORE_SOURCES=(
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPRawIO.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPCrypto.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPBlockDevice.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift"
)
PRODUCT_SOURCES=(
  "${REPO_ROOT}/product/EDPCredentialStore.swift"
  "${REPO_ROOT}/product/EDPDevicePolicyStore.swift"
  "${REPO_ROOT}/product/EDPMacFUSERuntimePolicy.swift"
  "${REPO_ROOT}/product/EDPLifecycleScheduler.swift"
  "${REPO_ROOT}/product/EDPLifecycleJournal.swift"
  "${REPO_ROOT}/product/EDPTransportProvider.swift"
  "${REPO_ROOT}/product/EDPTransportRuntimePolicy.swift"
  "${REPO_ROOT}/product/EDPFinderVolumeDefaults.swift"
  "${REPO_ROOT}/product/EDPNativeSystem.swift"
  "${REPO_ROOT}/product/EDPBlockDevicePublisher.swift"
  "${REPO_ROOT}/product/EDPXPCProtocol.swift"
  "${REPO_ROOT}/product/EDPXPCSecurity.swift"
  "${REPO_ROOT}/product/EDPRuntimeSupport.swift"
  "${REPO_ROOT}/product/EDPRuntimeState.swift"
  "${REPO_ROOT}/product/EDPDeviceOperations.swift"
  "${REPO_ROOT}/product/EDPDeviceDiscoveryController.swift"
  "${REPO_ROOT}/product/EDPRawAccess.swift"
  "${REPO_ROOT}/product/EDPRawAccessCoordinator.swift"
  "${REPO_ROOT}/product/EDPAutomationState.swift"
  "${REPO_ROOT}/product/EDPActivityStore.swift"
  "${REPO_ROOT}/product/EDPEjectCoordinator.swift"
  "${REPO_ROOT}/product/EDPServiceLifecycleState.swift"
  "${REPO_ROOT}/product/EDPRecoveryCoordinator.swift"
  "${REPO_ROOT}/product/EDPMountLifecycle.swift"
  "${REPO_ROOT}/product/EDPMountSupport.swift"
  "${REPO_ROOT}/product/EDPXPCService.swift"
  "${REPO_ROOT}/product/EDPServiceMain.swift"
  "${REPO_ROOT}/product/EDPVaultRuntime.swift"
)

echo "Building native privileged service..."
SERVICE_STAGE="${BUILD_ROOT}/edp-drive-service"
RAW_VALIDATION_OBJ="${BUILD_ROOT}/EDPRawValidation.o"
RAW_BROKER_OBJ="${BUILD_ROOT}/EDPRawFDBroker.o"
/usr/bin/cc -O2 -Wall -Wextra -I"${REPO_ROOT}/product" -c \
  "${REPO_ROOT}/product/EDPRawValidation.c" -o "${RAW_VALIDATION_OBJ}"
/usr/bin/cc -O2 -Wall -Wextra -I"${REPO_ROOT}/product" -c \
  "${REPO_ROOT}/product/EDPRawFDBroker.c" -o "${RAW_BROKER_OBJ}"
xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -Xfrontend -disable-availability-checking \
  -framework CryptoKit -framework Security -framework CoreFoundation -framework IOKit \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" "${PRODUCT_SOURCES[@]}" \
  "${RAW_VALIDATION_OBJ}" "${RAW_BROKER_OBJ}" \
  -o "${SERVICE_STAGE}"

echo "Building macFUSE Local transport..."
MACFUSE_FRAMEWORKS="/Library/Filesystems/macfuse.fs/Contents/Frameworks" \
  "${REPO_ROOT}/installer/build-transport-backends.sh" "${RUNTIME_STAGE}/bin"

/usr/bin/clang -fobjc-arc -fblocks \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/DiskImages2Attach.m" \
  -framework Foundation \
  -o "${RUNTIME_STAGE}/bin/diskimages2-attach"
/usr/bin/cc -O2 -Wall -Wextra -I"${REPO_ROOT}/product" \
  "${REPO_ROOT}/product/EDPConsoleExec.c" \
  "${REPO_ROOT}/product/EDPRawValidation.c" \
  -framework CoreFoundation -framework IOKit \
  -o "${RUNTIME_STAGE}/bin/edp-console-exec"
/usr/bin/cc -O2 -Wall -Wextra \
  "${REPO_ROOT}/product/EDPRawMetadataHelper.c" \
  -o "${RUNTIME_STAGE}/bin/edp-raw-metadata"

for item in "${RUNTIME_STAGE}/bin/"*; do
  sign_app_code "${item}"
done
sign_app_code --identifier com.edp.drive.service "${SERVICE_STAGE}"

echo "Building native menu-bar app..."
cp "${REPO_ROOT}/product/App/Info.plist" "${APP_STAGE}/Contents/Info.plist"
"${REPO_ROOT}/../../Tools/build-macos-icon.sh" icns \
  "${REPO_ROOT}/product/App/EDPDriveIcon.svg" \
  "${APP_STAGE}/Contents/Resources/EDPDrive.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION//./}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :EDPServiceMode ${SERVICE_MODE}" "${APP_STAGE}/Contents/Info.plist"
xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -framework AppKit -framework FSKit -framework SwiftUI \
  -framework ServiceManagement -framework CoreFoundation -framework IOKit \
  "${REPO_ROOT}/../../Shared/UI/EDPDesignSystem.swift" \
  "${REPO_ROOT}/product/EDPXPCProtocol.swift" \
  "${REPO_ROOT}/product/App/EDPUSBVaultApp.swift" \
  "${REPO_ROOT}/product/App/Service/EDPAppServiceSupport.swift" \
  "${REPO_ROOT}/product/App/Service/EDPXPCSmokeSupport.swift" \
  "${REPO_ROOT}/product/App/Model/EDPVaultViewModel.swift" \
  "${REPO_ROOT}/product/App/Sidebar/EDPSidebarView.swift" \
  "${REPO_ROOT}/product/App/Shell/EDPMainWindow.swift" \
  "${REPO_ROOT}/product/App/Pages/EDPOverviewView.swift" \
  "${REPO_ROOT}/product/App/Pages/EDPDevicesView.swift" \
  "${REPO_ROOT}/product/App/Pages/EDPActivityView.swift" \
  "${REPO_ROOT}/product/App/Pages/EDPSettingsView.swift" \
  "${REPO_ROOT}/product/App/MenuBar/EDPMenuBarView.swift" \
  "${RAW_VALIDATION_OBJ}" "${RAW_BROKER_OBJ}" \
  -o "${APP_STAGE}/Contents/MacOS/EDP Drive"
cp "${SERVICE_STAGE}" \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-drive-service"

cp "${REPO_ROOT}/product/App/com.edp.drive.service.plist" \
  "${APP_STAGE}/Contents/Library/LaunchDaemons/com.edp.drive.service.plist"
sign_app_code \
  --identifier com.edp.drive.service \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-drive-service"
sign_app_code \
  --identifier com.edp.drive "${APP_STAGE}"
/usr/bin/codesign --verify --strict "${APP_STAGE}"
if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
  SIGNING_INFO="$(/usr/bin/codesign -dv --verbose=4 "${APP_STAGE}" 2>&1)"
  /usr/bin/grep -Fq 'TeamIdentifier=not set' <<<"${SIGNING_INFO}"
  /usr/bin/grep -Fq 'Authority=' <<<"${SIGNING_INFO}"

  APP_REQUIREMENT="$(/usr/bin/codesign -dr - "${APP_STAGE}" 2>&1)"
  DAEMON_REQUIREMENT="$(/usr/bin/codesign -dr - "${APP_STAGE}/Contents/Library/LaunchServices/edp-drive-service" 2>&1)"
  /usr/bin/grep -Fq 'identifier "com.edp.drive"' <<<"${APP_REQUIREMENT}"
  APP_CERT_ROOT="$(/usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"${APP_REQUIREMENT}")"
  DAEMON_CERT_ROOT="$(/usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"${DAEMON_REQUIREMENT}")"
  [[ -n "${APP_CERT_ROOT}" && "${APP_CERT_ROOT}" == "${DAEMON_CERT_ROOT}" ]] || {
    echo "self-signed App and embedded service must share one stable certificate root for FDA/XPC continuity" >&2
    exit 2
  }
fi

PAYLOAD="${BUILD_ROOT}/payload"
PRODUCT_DIR="${PAYLOAD}/Library/Application Support/EDP Drive"
mkdir -p "${PRODUCT_DIR}/bin" "${PAYLOAD}/Applications"
cp -R "${RUNTIME_STAGE}/bin/." "${PRODUCT_DIR}/bin/"
cp -R "${APP_STAGE}" "${PAYLOAD}/Applications/EDP Drive.app"
if [[ "${SERVICE_MODE}" == "legacy" ]]; then
  mkdir -p "${PAYLOAD}/Library/LaunchDaemons"
  cp "${REPO_ROOT}/installer/com.edp.drive.service.plist" \
    "${PAYLOAD}/Library/LaunchDaemons/com.edp.drive.service.plist"
fi

SCRIPTS="${BUILD_ROOT}/scripts"
mkdir -p "${SCRIPTS}"
cp "${REPO_ROOT}/installer/scripts/native-preinstall" "${SCRIPTS}/preinstall"
cp "${REPO_ROOT}/installer/scripts/native-postinstall" "${SCRIPTS}/postinstall"
chmod 0755 "${SCRIPTS}/preinstall" "${SCRIPTS}/postinstall"

COMPONENT="${BUILD_ROOT}/EDP-Drive-Native.pkg"
COMPONENT_PLIST="${BUILD_ROOT}/native-component.plist"
/usr/bin/pkgbuild --analyze --root "${PAYLOAD}" "${COMPONENT_PLIST}"
# The one installed App owns both the foreground executable and the FDA service,
# so PackageKit must never relocate it away from its fixed /Applications path.
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c "Set :0:BundleHasStrictIdentifier true" "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked true" "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c "Set :0:BundleOverwriteAction upgrade" "${COMPONENT_PLIST}"
/usr/bin/pkgbuild \
  --root "${PAYLOAD}" \
  --identifier com.edp.drive.native \
  --version "${VERSION}" \
  --install-location / \
  --component-plist "${COMPONENT_PLIST}" \
  --scripts "${SCRIPTS}" \
  "${COMPONENT}"

OUTPUT="${OUTPUT_DIR}/EDP-Drive-${VERSION}-Native.pkg"
if [[ -n "${PRODUCT_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/productbuild --package "${COMPONENT}" --sign "${PRODUCT_SIGN_IDENTITY}" "${OUTPUT}"
else
  /usr/bin/productbuild --package "${COMPONENT}" "${OUTPUT}"
fi
/usr/bin/shasum -a 256 "${OUTPUT}" > "${OUTPUT}.sha256"
echo "OUTPUT=${OUTPUT}"
echo "TRANSPORT_RUNTIME=macfuse-local-only"
echo "RESULT=EDP_NATIVE_INSTALLER_BUILT"
if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
  echo "RESULT=SELF_SIGNED_DISTRIBUTION_PACKAGE"
fi
