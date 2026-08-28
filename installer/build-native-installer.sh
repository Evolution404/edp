#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${EDP_VERSION:-0.6.0}"
OUTPUT_DIR="${1:-${REPO_ROOT}/artifacts}"
APP_SIGN_IDENTITY="${EDP_APP_SIGN_IDENTITY:--}"
SERVICE_MODE="${EDP_SERVICE_MODE:-}"
if [[ -z "${SERVICE_MODE}" ]]; then
  [[ "${APP_SIGN_IDENTITY}" == "-" ]] && SERVICE_MODE="legacy" || SERVICE_MODE="smappservice"
fi
[[ "${SERVICE_MODE}" == "legacy" || "${SERVICE_MODE}" == "smappservice" ]]

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-native-installer.XXXXXX")"
cleanup() { /bin/rm -rf "${BUILD_ROOT}"; }
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
  "${REPO_ROOT}/product/EDPFuseTRuntimePolicy.swift"
  "${REPO_ROOT}/product/EDPMacFUSERuntimePolicy.swift"
  "${REPO_ROOT}/product/EDPTransportProvider.swift"
  "${REPO_ROOT}/product/EDPTransportRuntimePolicy.swift"
  "${REPO_ROOT}/product/EDPNativeSystem.swift"
  "${REPO_ROOT}/product/EDPBlockDevicePublisher.swift"
  "${REPO_ROOT}/product/EDPXPCProtocol.swift"
  "${REPO_ROOT}/product/EDPXPCSecurity.swift"
  "${REPO_ROOT}/product/EDPVaultRuntime.swift"
)

/usr/bin/cc -O2 -Wall -Wextra -c \
  "${REPO_ROOT}/product/EDPRawReadAuthorization.c" \
  -o "${BUILD_ROOT}/EDPRawReadAuthorization.o"
/usr/bin/cc -O2 -Wall -Wextra -c \
  "${REPO_ROOT}/product/EDPRawReadWriteAuthorization.c" \
  -o "${BUILD_ROOT}/EDPRawReadWriteAuthorization.o"

echo "Building native privileged service..."
xcrun swiftc -O -framework CryptoKit -framework Security \
  "${CORE_SOURCES[@]}" "${PRODUCT_SOURCES[@]}" \
  "${BUILD_ROOT}/EDPRawReadAuthorization.o" \
  "${BUILD_ROOT}/EDPRawReadWriteAuthorization.o" \
  -o "${RUNTIME_STAGE}/bin/edp-vaultctl"

echo "Building switchable transport backends (default macfuse-local)..."
MACFUSE_FRAMEWORKS="/Library/Filesystems/macfuse.fs/Contents/Frameworks" \
  "${REPO_ROOT}/installer/build-transport-backends.sh" "${RUNTIME_STAGE}/bin"

/usr/bin/clang -fobjc-arc -fblocks \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/DiskImages2Attach.m" \
  -framework Foundation \
  -o "${RUNTIME_STAGE}/bin/diskimages2-attach"
/usr/bin/cc -O2 -Wall -Wextra \
  "${REPO_ROOT}/product/EDPConsoleExec.c" \
  "${REPO_ROOT}/product/EDPRawReadWriteAuthorization.c" \
  -framework Security \
  -o "${RUNTIME_STAGE}/bin/edp-console-exec"
/usr/bin/cc -O2 -Wall -Wextra \
  "${REPO_ROOT}/product/EDPRawMetadataHelper.c" \
  "${REPO_ROOT}/product/EDPRawReadWriteAuthorization.c" \
  -framework Security \
  -o "${RUNTIME_STAGE}/bin/edp-raw-metadata"

for item in "${RUNTIME_STAGE}/bin/"*; do
  /usr/bin/codesign --force --sign "${APP_SIGN_IDENTITY}" "${item}"
done

echo "Building native menu-bar app..."
cp "${REPO_ROOT}/product/App/Info.plist" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION//./}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :EDPServiceMode ${SERVICE_MODE}" "${APP_STAGE}/Contents/Info.plist"
xcrun swiftc -O \
  -framework AppKit -framework FSKit -framework SwiftUI \
  -framework ServiceManagement -framework Security \
  "${REPO_ROOT}/product/EDPXPCProtocol.swift" \
  "${REPO_ROOT}/product/App/EDPUSBVaultApp.swift" \
  -o "${APP_STAGE}/Contents/MacOS/EDP USB Vault"
cp "${RUNTIME_STAGE}/bin/edp-vaultctl" \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-usbvaultd"

if [[ "${SERVICE_MODE}" == "smappservice" ]]; then
  cp "${REPO_ROOT}/product/App/com.edp.usbvault.mountd.v2.plist" \
    "${APP_STAGE}/Contents/Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist"
fi
/usr/bin/codesign --force --sign "${APP_SIGN_IDENTITY}" \
  --identifier com.edp.usbvault.mountd.v2 \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-usbvaultd"
/usr/bin/codesign --force --sign "${APP_SIGN_IDENTITY}" \
  --identifier com.edp.usbvault.app "${APP_STAGE}"
/usr/bin/codesign --verify --strict "${APP_STAGE}"

PAYLOAD="${BUILD_ROOT}/payload"
PRODUCT_DIR="${PAYLOAD}/Library/Application Support/EDP USB Vault"
mkdir -p "${PRODUCT_DIR}/bin" "${PAYLOAD}/Applications" "${PAYLOAD}/usr/local/bin"
cp -R "${RUNTIME_STAGE}/bin/." "${PRODUCT_DIR}/bin/"
cp -R "${APP_STAGE}" "${PAYLOAD}/Applications/EDP USB Vault.app"
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
/usr/bin/pkgbuild \
  --root "${PAYLOAD}" \
  --identifier com.edp.usbvault.native \
  --version "${VERSION}" \
  --install-location / \
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
echo "FUSET_RUNTIME=external-pinned-1.2.7"
echo "RESULT=EDP_NATIVE_INSTALLER_BUILT"
