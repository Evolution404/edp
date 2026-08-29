#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${REPO_ROOT}/scripts/prepare-shared-edp-core.sh"
VERSION="${EDP_VERSION:-0.5.0}"
ARCH="${EDP_ARCH:-arm64}"
OUTPUT_DIR="${1:-${REPO_ROOT}/artifacts}"
MACFUSE_VERSION="5.3.3"
MACFUSE_SHA256="7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15"
MACFUSE_URL="https://github.com/macfuse/macfuse/releases/download/macfuse-${MACFUSE_VERSION}/macfuse-${MACFUSE_VERSION}.dmg"
MACFUSE_DMG="${MACFUSE_DMG:-}"
MACFUSE_LICENSE_FILE="${MACFUSE_LICENSE_FILE:-}"
APP_SIGN_IDENTITY="${EDP_APP_SIGN_IDENTITY:--}"
APP_SIGN_KEYCHAIN="${EDP_APP_SIGN_KEYCHAIN:-}"
SERVICE_MODE="${EDP_SERVICE_MODE:-}"
LEGACY_DIAGNOSTIC="${EDP_LEGACY_DIAGNOSTIC:-0}"
SELF_SIGNED_DISTRIBUTION="${EDP_SELF_SIGNED_DISTRIBUTION:-0}"
if [[ -z "${SERVICE_MODE}" ]]; then
  [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]] && SERVICE_MODE="legacy" || SERVICE_MODE="smappservice"
fi
[[ "${SERVICE_MODE}" == "legacy" || "${SERVICE_MODE}" == "smappservice" ]] || {
  echo "invalid EDP_SERVICE_MODE: ${SERVICE_MODE}" >&2
  exit 2
}
if [[ "${SERVICE_MODE}" == "legacy" && "${LEGACY_DIAGNOSTIC}" != "1" && "${SELF_SIGNED_DISTRIBUTION}" != "1" ]]; then
  echo "legacy LaunchDaemon mode requires an explicit distribution policy" >&2
  echo "set EDP_SELF_SIGNED_DISTRIBUTION=1 for the self-signed community package" >&2
  echo "or EDP_LEGACY_DIAGNOSTIC=1 for CI-only contract tests" >&2
  exit 2
fi
if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
  [[ "${SERVICE_MODE}" == "legacy" ]] || {
    echo "self-signed distribution requires EDP_SERVICE_MODE=legacy" >&2
    exit 2
  }
  [[ "${APP_SIGN_IDENTITY}" != "-" ]] || {
    echo "self-signed distribution requires a stable non-ad-hoc code-signing identity" >&2
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

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-clean-installer.XXXXXX")"
MACFUSE_MOUNT="${BUILD_ROOT}/macfuse"

cleanup() {
  restore_signing_search_list
  /usr/bin/hdiutil detach -quiet "${MACFUSE_MOUNT}" >/dev/null 2>&1 || true
  rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT INT TERM

mkdir -p "${OUTPUT_DIR}" "${MACFUSE_MOUNT}"

if [[ -z "${MACFUSE_DMG}" ]]; then
  MACFUSE_DMG="${BUILD_ROOT}/macfuse-${MACFUSE_VERSION}.dmg"
  /usr/bin/curl --fail --location --retry 5 --retry-all-errors \
    --output "${MACFUSE_DMG}" "${MACFUSE_URL}"
fi
[[ -f "${MACFUSE_DMG}" ]] || {
  echo "macFUSE dmg not found: ${MACFUSE_DMG}" >&2
  exit 2
}
printf '%s  %s\n' "${MACFUSE_SHA256}" "${MACFUSE_DMG}" | /usr/bin/shasum -a 256 -c -

RUNTIME_STAGE="${BUILD_ROOT}/runtime"
mkdir -p "${RUNTIME_STAGE}/bin" "${RUNTIME_STAGE}/licenses/macfuse"

echo "Building EDP encrypted block runtime..."
CORE_SOURCES=(
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPRawIO.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPCrypto.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPBlockDevice.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift"
)

xcrun swiftc -O -framework CryptoKit -framework Security \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  "${REPO_ROOT}/product/EDPCredentialStore.swift" \
  "${REPO_ROOT}/product/EDPDevicePolicyStore.swift" \
  "${REPO_ROOT}/product/EDPMacFUSERuntimePolicy.swift" \
  "${REPO_ROOT}/product/EDPTransportProvider.swift" \
  "${REPO_ROOT}/product/EDPTransportRuntimePolicy.swift" \
  "${REPO_ROOT}/product/EDPFinderVolumeDefaults.swift" \
  "${REPO_ROOT}/product/EDPNativeSystem.swift" \
  "${REPO_ROOT}/product/EDPBlockDevicePublisher.swift" \
  "${REPO_ROOT}/product/EDPXPCProtocol.swift" \
  "${REPO_ROOT}/product/EDPXPCSecurity.swift" \
  "${REPO_ROOT}/product/EDPVaultRuntime.swift" \
  -o "${RUNTIME_STAGE}/bin/edp-vaultctl"

xcrun swiftc -O -emit-library -module-name EDPReadWriteBridge \
  -Xlinker -install_name -Xlinker @rpath/libEDPReadWriteBridge.dylib \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/EDPReadOnlyBlockCBridge.swift" \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/EDPReadWriteBlockCBridge.swift" \
  -o "${RUNTIME_STAGE}/bin/libEDPReadWriteBridge.dylib"

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

echo "Building SwiftUI app..."
APP_STAGE="${BUILD_ROOT}/EDP Drive.app"
mkdir -p "${APP_STAGE}/Contents/MacOS" "${APP_STAGE}/Contents/Resources" \
  "${APP_STAGE}/Contents/Library/LaunchDaemons" \
  "${APP_STAGE}/Contents/Library/LaunchServices"
cp "${REPO_ROOT}/product/App/Info.plist" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION//./}" "${APP_STAGE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :EDPServiceMode ${SERVICE_MODE}" "${APP_STAGE}/Contents/Info.plist"
xcrun swiftc -O \
  -framework AppKit -framework FSKit -framework SwiftUI -framework ServiceManagement \
  "${REPO_ROOT}/product/EDPXPCProtocol.swift" \
  "${REPO_ROOT}/product/App/EDPUSBVaultApp.swift" \
  -o "${APP_STAGE}/Contents/MacOS/EDP Drive"
cp "${RUNTIME_STAGE}/bin/edp-vaultctl" \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-drive-service"
if [[ "${SERVICE_MODE}" == "smappservice" ]]; then
cat > "${APP_STAGE}/Contents/Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.edp.usbvault.mountd.v2</string>
  <key>BundleProgram</key>
  <string>Contents/Library/LaunchServices/edp-drive-service</string>
  <key>ProgramArguments</key>
  <array>
    <string>edp-drive-service</string>
    <string>daemon</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>EDP_RUNTIME_BIN_ROOT</key>
    <string>/Library/Application Support/EDP USB Vault/bin</string>
  </dict>
  <key>MachServices</key>
  <dict>
    <key>com.edp.usbvault.xpc</key><true/>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/var/log/edp-usbvault.log</string>
  <key>StandardErrorPath</key><string>/var/log/edp-usbvault.log</string>
</dict>
</plist>
PLIST
/bin/chmod 0644 "${APP_STAGE}/Contents/Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist"
fi
sign_app_code \
  --identifier com.edp.usbvault.mountd.v2 \
  "${APP_STAGE}/Contents/Library/LaunchServices/edp-drive-service"
sign_app_code --identifier com.edp.usbvault.app "${APP_STAGE}"
/usr/bin/codesign --verify --strict "${APP_STAGE}"
if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
  SIGNING_INFO="$(/usr/bin/codesign -dv --verbose=4 "${APP_STAGE}" 2>&1)"
  /usr/bin/grep -Fq 'TeamIdentifier=not set' <<<"${SIGNING_INFO}" || {
    echo "self-signed distribution identity unexpectedly has an Apple TeamIdentifier" >&2
    exit 2
  }
  /usr/bin/grep -Fq 'Authority=' <<<"${SIGNING_INFO}" || {
    echo "self-signed distribution requires a certificate-backed signature, not ad-hoc signing" >&2
    exit 2
  }

  APP_REQUIREMENT="$(/usr/bin/codesign -dr - "${APP_STAGE}" 2>&1)"
  DAEMON_REQUIREMENT="$(/usr/bin/codesign -dr - "${APP_STAGE}/Contents/Library/LaunchServices/edp-drive-service" 2>&1)"
  /usr/bin/grep -Fq 'identifier "com.edp.usbvault.app"' <<<"${APP_REQUIREMENT}"
  APP_CERT_ROOT="$(/usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"${APP_REQUIREMENT}")"
  DAEMON_CERT_ROOT="$(/usr/bin/sed -n 's/.*certificate root = H"\([0-9A-Fa-f]*\)".*/\1/p' <<<"${DAEMON_REQUIREMENT}")"
  [[ -n "${APP_CERT_ROOT}" && "${APP_CERT_ROOT}" == "${DAEMON_CERT_ROOT}" ]] || {
    echo "self-signed App and embedded service must share one stable certificate root for FDA/XPC continuity" >&2
    exit 2
  }
fi

if [[ -n "${MACFUSE_LICENSE_FILE}" ]]; then
  [[ -f "${MACFUSE_LICENSE_FILE}" ]] || {
    echo "macFUSE license file not found: ${MACFUSE_LICENSE_FILE}" >&2
    exit 2
  }
  cp "${MACFUSE_LICENSE_FILE}" "${RUNTIME_STAGE}/licenses/macfuse/LICENSE.txt"
else
  /usr/bin/curl --fail --location --retry 5 --retry-all-errors \
    --output "${RUNTIME_STAGE}/licenses/macfuse/LICENSE.txt" \
    "https://raw.githubusercontent.com/macfuse/macfuse/macfuse-5.3.3/LICENSE.txt"
fi
printf '%s  %s\n' \
  1201956ec47b2c53c4c4fe7751be6d6f55fefcc44a6eca08780a94e009bcdbcd \
  "${RUNTIME_STAGE}/licenses/macfuse/LICENSE.txt" \
  | /usr/bin/shasum -a 256 -c -

PAYLOAD="${BUILD_ROOT}/payload"
PRODUCT_DIR="${PAYLOAD}/Library/Application Support/EDP USB Vault"
mkdir -p "${PRODUCT_DIR}" "${PAYLOAD}/usr/local/bin" "${PAYLOAD}/Applications"
cp -R "${RUNTIME_STAGE}/." "${PRODUCT_DIR}/"
cp -R "${APP_STAGE}" "${PAYLOAD}/Applications/EDP Drive.app"
ln -s "/Library/Application Support/EDP USB Vault/bin/edp-vaultctl" \
  "${PAYLOAD}/usr/local/bin/edp-vaultctl"
if [[ "${SERVICE_MODE}" == "legacy" ]]; then
  mkdir -p "${PAYLOAD}/Library/LaunchDaemons"
  cat > "${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.edp.usbvault.mountd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/EDP Drive.app/Contents/Library/LaunchServices/edp-drive-service</string>
    <string>daemon</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>EDP_RUNTIME_BIN_ROOT</key>
    <string>/Library/Application Support/EDP USB Vault/bin</string>
  </dict>
  <key>MachServices</key>
  <dict>
    <key>com.edp.usbvault.xpc</key><true/>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/var/log/edp-usbvault.log</string>
  <key>StandardErrorPath</key><string>/var/log/edp-usbvault.log</string>
</dict>
</plist>
PLIST
  /bin/chmod 0644 "${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
fi

SCRIPTS="${BUILD_ROOT}/scripts"
mkdir -p "${SCRIPTS}"
cat > "${SCRIPTS}/preinstall" <<'PREINSTALL'
#!/bin/bash
set -e
LEGACY_PLIST="/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
if [[ -f "${LEGACY_PLIST}" ]]; then
  /bin/launchctl bootout system/com.edp.usbvault.mountd >/dev/null 2>&1 || true
  /bin/rm -f "${LEGACY_PLIST}"
fi
OLD_ROOT="/Library/Application Support/EDP USB Vault"
OLD_CTL="${OLD_ROOT}/bin/edp-vaultctl"
if [[ -x "${OLD_CTL}" ]]; then
  "${OLD_CTL}" cleanup >/dev/null 2>&1 || true
fi
for RETIRED_RUNTIME in edp-readwrite-fuse edp-raw-sparse; do
  /bin/rm -f "${OLD_ROOT}/bin/${RETIRED_RUNTIME}"
done
OLD_APP="/Applications/EDP USB Vault.app"
if [[ -f "${OLD_APP}/Contents/Info.plist" ]]; then
  OLD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${OLD_APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${OLD_ID}" == "com.edp.usbvault" ]]; then
    /bin/rm -rf "${OLD_APP}"
  fi
fi
OLD_RAW_ACCESS_APP="/Applications/EDP USB Vault Raw Access.app"
if [[ -f "${OLD_RAW_ACCESS_APP}/Contents/Info.plist" ]]; then
  OLD_RAW_ACCESS_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${OLD_RAW_ACCESS_APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${OLD_RAW_ACCESS_ID}" == "com.edp.usbvault.rawaccess" ]]; then
    /bin/rm -rf "${OLD_RAW_ACCESS_APP}"
  fi
fi
for RELOCATED_APP_DIR in /Applications/EDP\ USB\ Vault*.localized; do
  [[ -e "${RELOCATED_APP_DIR}" ]] || continue
  /bin/rm -rf "${RELOCATED_APP_DIR}"
done
exit 0
PREINSTALL
cat > "${SCRIPTS}/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -e
ROOT="/Library/Application Support/EDP USB Vault"
APP="/Applications/EDP Drive.app"
/usr/sbin/chown -R root:wheel "${ROOT}" "${APP}"
/bin/chmod -R go-w "${ROOT}" "${APP}"
/bin/chmod 0755 "${ROOT}" "${ROOT}/bin"
/bin/chmod 0755 "${ROOT}/bin/"*
/usr/bin/xattr -dr com.apple.quarantine "${ROOT}" "${APP}" >/dev/null 2>&1 || true
LEGACY_PLIST="/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
if [[ -f "${LEGACY_PLIST}" ]]; then
  /bin/launchctl bootstrap system "${LEGACY_PLIST}"
  /bin/launchctl enable system/com.edp.usbvault.mountd || true
  /bin/launchctl kickstart -k system/com.edp.usbvault.mountd || true
fi
if /bin/launchctl print system/com.edp.usbvault.mountd.v2 >/dev/null 2>&1; then
  # Registration remains owned by SMAppService. Restart the approved job so
  # package upgrades immediately execute the newly installed daemon binary.
  /bin/launchctl kickstart -k system/com.edp.usbvault.mountd.v2 || true
fi
exit 0
POSTINSTALL
chmod 0755 "${SCRIPTS}/preinstall" "${SCRIPTS}/postinstall"

APP_COMPONENT="${BUILD_ROOT}/components/ZZ-EDP-USB-Vault.pkg"
COMPONENT_PLIST="${BUILD_ROOT}/edp-component.plist"
mkdir -p "${BUILD_ROOT}/components"
/usr/bin/pkgbuild --analyze --root "${PAYLOAD}" "${COMPONENT_PLIST}"
# The one installed App owns the foreground executable and embedded FDA service.
# PackageKit must not relocate it away from the fixed /Applications path.
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c 'Set :0:BundleHasStrictIdentifier true' "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked true' "${COMPONENT_PLIST}"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "${COMPONENT_PLIST}"
/usr/bin/pkgbuild \
  --root "${PAYLOAD}" \
  --identifier com.edp.usbvault.runtime \
  --version "${VERSION}" \
  --install-location / \
  --component-plist "${COMPONENT_PLIST}" \
  --scripts "${SCRIPTS}" \
  "${APP_COMPONENT}"

echo "Embedding the original signed macFUSE installer components..."
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "${MACFUSE_MOUNT}" "${MACFUSE_DMG}"
MACFUSE_PRODUCT="$(find "${MACFUSE_MOUNT}" -maxdepth 2 -name 'Install macFUSE*.pkg' -print -quit)"
[[ -n "${MACFUSE_PRODUCT}" ]] || {
  echo "signed macFUSE product package not found in dmg" >&2
  exit 3
}
MACFUSE_EXPANDED="${BUILD_ROOT}/macfuse-expanded"
/usr/sbin/pkgutil --expand "${MACFUSE_PRODUCT}" "${MACFUSE_EXPANDED}"
while IFS= read -r -d '' package; do
  # Expanded product components are directory packages. Flatten each one back
  # to the canonical xar form before handing it to productbuild. Passing the
  # directory archive directly triggers a PackageKit crash on macOS 26.
  /usr/sbin/pkgutil --flatten \
    "${package}" \
    "${BUILD_ROOT}/components/$(basename "${package}")"
done < <(find "${MACFUSE_EXPANDED}" -maxdepth 2 -name '*.pkg' -print0)
/usr/bin/hdiutil detach -quiet "${MACFUSE_MOUNT}"

COMPONENT_COUNT="$(find "${BUILD_ROOT}/components" -maxdepth 1 -name '*.pkg' | wc -l | tr -d ' ')"
[[ "${COMPONENT_COUNT}" -gt 1 ]] || {
  echo "macFUSE component packages were not extracted" >&2
  exit 4
}

DIST="${BUILD_ROOT}/Distribution.xml"
PRODUCTBUILD_ARGS=(--synthesize)
while IFS= read -r -d '' package; do
  PRODUCTBUILD_ARGS+=(--package "${package}")
done < <(find "${BUILD_ROOT}/components" -maxdepth 1 -name '*.pkg' -print0 | sort -z)
/usr/bin/productbuild "${PRODUCTBUILD_ARGS[@]}" "${DIST}"

/usr/bin/python3 - "${DIST}" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '<installer-gui-script minSpecVersion="1">'
if '<title>' not in s:
    s = s.replace(needle, needle + '\n    <title>EDP USB Vault + macFUSE FSKit</title>', 1)
p.write_text(s)
PY

OUTPUT_PKG="${OUTPUT_DIR}/EDP-USB-Vault-${VERSION}-${ARCH}-Clean.pkg"
FINAL_ARGS=(
  --distribution "${DIST}"
  --package-path "${BUILD_ROOT}/components"
)
if [[ -n "${PRODUCT_SIGN_IDENTITY:-}" ]]; then
  FINAL_ARGS+=(--sign "${PRODUCT_SIGN_IDENTITY}")
fi
/usr/bin/productbuild "${FINAL_ARGS[@]}" "${OUTPUT_PKG}"

/usr/sbin/pkgutil --check-signature "${OUTPUT_PKG}" || true
/usr/bin/shasum -a 256 "${OUTPUT_PKG}" \
  > "${OUTPUT_DIR}/EDP-USB-Vault-${VERSION}-${ARCH}-Clean.pkg.sha256"

echo "OUTPUT=${OUTPUT_PKG}"
echo "MACFUSE_VERSION=${MACFUSE_VERSION}"
echo "RESULT=EDP_CLEAN_COMBINED_INSTALLER_BUILT"
if [[ "${SELF_SIGNED_DISTRIBUTION}" == "1" ]]; then
  echo "RESULT=SELF_SIGNED_DISTRIBUTION_PACKAGE"
elif [[ "${SERVICE_MODE}" == "legacy" ]]; then
  echo "RESULT=CI_ONLY_LEGACY_DIAGNOSTIC_PACKAGE"
else
  echo "RESULT=PHYSICAL_USB_SERVICE_CONTEXT_PACKAGED"
fi
