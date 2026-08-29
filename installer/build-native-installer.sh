#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
APP_STAGE="${BUILD_ROOT}/EDP USB Vault.app"
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
  "${REPO_ROOT}/product/EDPTransportProvider.swift"
  "${REPO_ROOT}/product/EDPTransportRuntimePolicy.swift"
  "${REPO_ROOT}/product/EDPFinderVolumeDefaults.swift"
  "${REPO_ROOT}/product/EDPNativeSystem.swift"
  "${REPO_ROOT}/product/EDPBlockDevicePublisher.swift"
  "${REPO_ROOT}/product/EDPXPCProtocol.swift"
  "${REPO_ROOT}/product/EDPXPCSecurity.swift"
  "${REPO_ROOT}/product/EDPVaultRuntime.swift"
)

echo "Building native privileged service..."
xcrun swiftc -O -framework CryptoKit -framework Security \
  "${CORE_SOURCES[@]}" "${PRODUCT_SOURCES[@]}" \
  -o "${RUNTIME_STAGE}/bin/edp-vaultctl"

echo "Building macFUSE Local transport..."
MACFUSE_FRAMEWORKS="/Library/Filesystems/macfuse.fs/Contents/Frameworks" \
  "${REPO_ROOT}/installer/build-transport-backends.sh" "${RUNTIME_STAGE}/bin"

/usr/bin/clang -fobjc-arc -fblocks \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/DiskImages2Attach.m" \
  -framework Foundation \
  -o "${RUNTIME_STAGE}/bin/diskimages2-attach"
/usr/bin/cc -O2 -Wall -Wextra \
  "${REPO_ROOT}/product/EDPConsoleExec.c" \
  -framework CoreFoundation -framework IOKit \
  -o "${RUNTIME_STAGE}/bin/edp-console-exec"
/usr/bin/cc -O2 -Wall -Wextra \
  "${REPO_ROOT}/product/EDPRawMetadataHelper.c" \
  -o "${RUNTIME_STAGE}/bin/edp-raw-metadata"

for item in "${RUNTIME_STAGE}/bin/"*; do
  sign_app_code "${item}"
done

RAW_ACCESS_APP_STAGE="${BUILD_ROOT}/EDP USB Vault Raw Access.app"
mkdir -p "${RAW_ACCESS_APP_STAGE}/Contents/MacOS"
cp "${REPO_ROOT}/product/RawAccessHelper/Info.plist" \
  "${RAW_ACCESS_APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
  "${RAW_ACCESS_APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION//./}" \
  "${RAW_ACCESS_APP_STAGE}/Contents/Info.plist"
cp "${RUNTIME_STAGE}/bin/edp-vaultctl" \
  "${RAW_ACCESS_APP_STAGE}/Contents/MacOS/edp-usbvaultd"
sign_app_code \
  --identifier com.edp.usbvault.rawaccess \
  "${RAW_ACCESS_APP_STAGE}"
/usr/bin/codesign --verify --strict "${RAW_ACCESS_APP_STAGE}"

echo "Building native menu-bar app..."
cp "${REPO_ROOT}/product/App/Info.plist" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION//./}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :EDPServiceMode ${SERVICE_MODE}" "${APP_STAGE}/Contents/Info.plist"
xcrun swiftc -O \
  -framework AppKit -framework FSKit -framework SwiftUI \
  -framework ServiceManagement \
  "${REPO_ROOT}/product/EDPXPCProtocol.swift" \
  "${REPO_ROOT}/product/App/EDPUSBVaultApp.swift" \
  -o "${APP_STAGE}/Contents/MacOS/EDP USB Vault"
cp "${RUNTIME_STAGE}/bin/edp-vaultctl" \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-usbvaultd"

if [[ "${SERVICE_MODE}" == "smappservice" ]]; then
  cp "${REPO_ROOT}/product/App/com.edp.usbvault.mountd.v2.plist" \
    "${APP_STAGE}/Contents/Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist"
fi
sign_app_code \
  --identifier com.edp.usbvault.mountd.v2 \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-usbvaultd"
sign_app_code \
  --identifier com.edp.usbvault.app "${APP_STAGE}"
/usr/bin/codesign --verify --strict "${APP_STAGE}"
if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
  SIGNING_INFO="$(/usr/bin/codesign -dv --verbose=4 "${APP_STAGE}" 2>&1)"
  /usr/bin/grep -Fq 'TeamIdentifier=not set' <<<"${SIGNING_INFO}"
  /usr/bin/grep -Fq 'Authority=' <<<"${SIGNING_INFO}"

  APP_REQUIREMENT="$(/usr/bin/codesign -dr - "${APP_STAGE}" 2>&1)"
  RAW_REQUIREMENT="$(/usr/bin/codesign -dr - "${RAW_ACCESS_APP_STAGE}" 2>&1)"
  DAEMON_REQUIREMENT="$(/usr/bin/codesign -dr - "${RUNTIME_STAGE}/bin/edp-vaultctl" 2>&1)"
  /usr/bin/grep -Fq 'identifier "com.edp.usbvault.app"' <<<"${APP_REQUIREMENT}"
  /usr/bin/grep -Fq 'identifier "com.edp.usbvault.rawaccess"' <<<"${RAW_REQUIREMENT}"
  APP_CERT_ROOT="$(/usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"${APP_REQUIREMENT}")"
  RAW_CERT_ROOT="$(/usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"${RAW_REQUIREMENT}")"
  DAEMON_CERT_ROOT="$(/usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"${DAEMON_REQUIREMENT}")"
  [[ -n "${APP_CERT_ROOT}" && "${APP_CERT_ROOT}" == "${RAW_CERT_ROOT}" && "${APP_CERT_ROOT}" == "${DAEMON_CERT_ROOT}" ]] || {
    echo "self-signed App, raw-access helper, and daemon must share one stable certificate root for FDA/XPC continuity" >&2
    exit 2
  }
fi

PAYLOAD="${BUILD_ROOT}/payload"
PRODUCT_DIR="${PAYLOAD}/Library/Application Support/EDP USB Vault"
mkdir -p "${PRODUCT_DIR}/bin" "${PAYLOAD}/Applications" "${PAYLOAD}/usr/local/bin"
cp -R "${RUNTIME_STAGE}/bin/." "${PRODUCT_DIR}/bin/"
cp -R "${APP_STAGE}" "${PAYLOAD}/Applications/EDP USB Vault.app"
cp -R "${RAW_ACCESS_APP_STAGE}" \
  "${PAYLOAD}/Applications/EDP USB Vault Raw Access.app"
ln -s "/Library/Application Support/EDP USB Vault/bin/edp-vaultctl" \
  "${PAYLOAD}/usr/local/bin/edp-vaultctl"

if [[ "${SERVICE_MODE}" == "legacy" ]]; then
  mkdir -p "${PAYLOAD}/Library/LaunchDaemons"
  cp "${REPO_ROOT}/product/App/com.edp.usbvault.mountd.legacy.plist" \
    "${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
fi

SCRIPTS="${BUILD_ROOT}/scripts"
mkdir -p "${SCRIPTS}"
cp "${REPO_ROOT}/installer/scripts/native-preinstall" "${SCRIPTS}/preinstall"
cp "${REPO_ROOT}/installer/scripts/native-postinstall" "${SCRIPTS}/postinstall"
chmod 0755 "${SCRIPTS}/preinstall" "${SCRIPTS}/postinstall"

COMPONENT="${BUILD_ROOT}/EDP-USB-Vault-Native.pkg"
COMPONENT_PLIST="${BUILD_ROOT}/native-component.plist"
/usr/bin/pkgbuild --analyze --root "${PAYLOAD}" "${COMPONENT_PLIST}"
# Both installed application bundles have fixed /Applications paths. In
# particular, relocating com.edp.usbvault.rawaccess would break the stable FDA
# identity/path contract used by the privileged daemon.
for INDEX in 0 1; do
  /usr/libexec/PlistBuddy -c "Set :${INDEX}:BundleIsRelocatable false" "${COMPONENT_PLIST}"
  /usr/libexec/PlistBuddy -c "Set :${INDEX}:BundleHasStrictIdentifier true" "${COMPONENT_PLIST}"
  /usr/libexec/PlistBuddy -c "Set :${INDEX}:BundleIsVersionChecked true" "${COMPONENT_PLIST}"
  /usr/libexec/PlistBuddy -c "Set :${INDEX}:BundleOverwriteAction upgrade" "${COMPONENT_PLIST}"
done
/usr/bin/pkgbuild \
  --root "${PAYLOAD}" \
  --identifier com.edp.usbvault.native \
  --version "${VERSION}" \
  --install-location / \
  --component-plist "${COMPONENT_PLIST}" \
  --scripts "${SCRIPTS}" \
  "${COMPONENT}"

OUTPUT="${OUTPUT_DIR}/EDP-USB-Vault-${VERSION}-Native.pkg"
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
