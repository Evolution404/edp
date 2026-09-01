#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-${REPO_ROOT}/artifacts}"
INSTALLED_APP="${EDP_INSTALLED_APP:-/Applications/EDP Drive.app}"
SIGN_IDENTITY="${EDP_APP_SIGN_IDENTITY:-EDP Project Code Signing}"
REVISION="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse --short HEAD)"
PACKAGE_VERSION="${EDP_UI_PACKAGE_VERSION:-0.6.0.$(/usr/bin/git -C "${REPO_ROOT}" rev-list --count HEAD)}"
OUTPUT="${OUTPUT_DIR}/EDP-Drive-UI-${REVISION}.pkg"

[[ -d "${INSTALLED_APP}" ]] || {
  echo "Installed EDP Drive was not found at ${INSTALLED_APP}. Build the full installer first." >&2
  exit 2
}
/usr/bin/security find-identity -v -p codesigning \
  | /usr/bin/grep -Fq "\"${SIGN_IDENTITY}\"" || {
    echo "Code-signing identity is unavailable: ${SIGN_IDENTITY}" >&2
    exit 2
  }

certificate_root() {
  /usr/bin/codesign -dr - "$1" 2>&1 \
    | /usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p'
}

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-drive-ui-update.XXXXXX")"
cleanup() {
  /bin/rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT INT TERM

PAYLOAD="${BUILD_ROOT}/payload"
APP_STAGE="${PAYLOAD}/Applications/EDP Drive.app"
/bin/mkdir -p "${PAYLOAD}/Applications" "${OUTPUT_DIR}"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
  "${INSTALLED_APP}" "${APP_STAGE}"

echo "Building EDP Drive foreground UI..."
RAW_VALIDATION_OBJ="${BUILD_ROOT}/EDPRawValidation.o"
RAW_BROKER_OBJ="${BUILD_ROOT}/EDPRawFDBroker.o"
/usr/bin/cc -O2 -Wall -Wextra -I"${REPO_ROOT}/Apps/Drive/product" -c \
  "${REPO_ROOT}/Apps/Drive/product/EDPRawValidation.c" -o "${RAW_VALIDATION_OBJ}"
/usr/bin/cc -O2 -Wall -Wextra -I"${REPO_ROOT}/Apps/Drive/product" -c \
  "${REPO_ROOT}/Apps/Drive/product/EDPRawFDBroker.c" -o "${RAW_BROKER_OBJ}"
xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -framework AppKit -framework FSKit -framework SwiftUI \
  -framework ServiceManagement -framework CoreFoundation -framework IOKit \
  "${REPO_ROOT}/Shared/UI/EDPDesignSystem.swift" \
  "${REPO_ROOT}/Apps/Drive/product/EDPXPCProtocol.swift" \
  "${REPO_ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift" \
  "${RAW_VALIDATION_OBJ}" "${RAW_BROKER_OBJ}" \
  -o "${APP_STAGE}/Contents/MacOS/EDP Drive"

INSTALLED_CERT_ROOT="$(certificate_root "${INSTALLED_APP}")"
/usr/bin/codesign --force --sign "${SIGN_IDENTITY}" \
  --identifier com.edp.drive "${APP_STAGE}"
/usr/bin/codesign --verify --strict "${APP_STAGE}"
STAGED_CERT_ROOT="$(certificate_root "${APP_STAGE}")"
[[ -n "${INSTALLED_CERT_ROOT}" && "${INSTALLED_CERT_ROOT}" == "${STAGED_CERT_ROOT}" ]] || {
  echo "UI update must retain the installed App certificate root." >&2
  exit 2
}

COMPONENT_PLIST="${BUILD_ROOT}/component.plist"
/usr/bin/pkgbuild --analyze --root "${PAYLOAD}" "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c 'Set :0:BundleHasStrictIdentifier true' "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "${COMPONENT_PLIST}"

/bin/rm -f "${OUTPUT}" "${OUTPUT}.sha256" "${OUTPUT}.ui-sha256"
/usr/bin/pkgbuild \
  --root "${PAYLOAD}" \
  --identifier com.edp.drive.ui-update \
  --version "${PACKAGE_VERSION}" \
  --install-location / \
  --component-plist "${COMPONENT_PLIST}" \
  "${OUTPUT}"

UI_SHA="$(/usr/bin/shasum -a 256 "${APP_STAGE}/Contents/MacOS/EDP Drive" | /usr/bin/awk '{print $1}')"
/usr/bin/shasum -a 256 "${OUTPUT}" > "${OUTPUT}.sha256"
/usr/bin/printf '%s  %s\n' \
  "${UI_SHA}" '/Applications/EDP Drive.app/Contents/MacOS/EDP Drive' \
  > "${OUTPUT}.ui-sha256"

echo "OUTPUT=${OUTPUT}"
echo "RESULT=EDP_DRIVE_UI_UPDATE_BUILT"
