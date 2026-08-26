#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${EDP_VERSION:-0.5.0}"
ARCH="${EDP_ARCH:-arm64}"
OUTPUT_DIR="${1:-${REPO_ROOT}/artifacts}"
MACFUSE_VERSION="5.3.3"
MACFUSE_SHA256="7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15"
MACFUSE_URL="https://github.com/macfuse/macfuse/releases/download/macfuse-${MACFUSE_VERSION}/macfuse-${MACFUSE_VERSION}.dmg"
MACFUSE_DMG="${MACFUSE_DMG:-}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-clean-installer.XXXXXX")"
MACFUSE_MOUNT="${BUILD_ROOT}/macfuse"

cleanup() {
  /usr/bin/hdiutil detach -quiet "${MACFUSE_MOUNT}" >/dev/null 2>&1 || true
  rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT INT TERM

mkdir -p "${OUTPUT_DIR}" "${MACFUSE_MOUNT}"

if [[ -z "${MACFUSE_DMG}" ]]; then
  MACFUSE_DMG="${BUILD_ROOT}/macfuse-${MACFUSE_VERSION}.dmg"
  /usr/bin/curl --fail --location --retry 3 --output "${MACFUSE_DMG}" "${MACFUSE_URL}"
fi
[[ -f "${MACFUSE_DMG}" ]] || {
  echo "macFUSE dmg not found: ${MACFUSE_DMG}" >&2
  exit 2
}
printf '%s  %s\n' "${MACFUSE_SHA256}" "${MACFUSE_DMG}" | /usr/bin/shasum -a 256 -c -

RUNTIME_STAGE="${BUILD_ROOT}/runtime"
mkdir -p "${RUNTIME_STAGE}/bin" "${RUNTIME_STAGE}/lib" \
  "${RUNTIME_STAGE}/licenses/macfuse"

echo "Building reproducible NTFS-3G runtime..."
if [[ -n "${NTFS3G_RUNTIME:-}" ]]; then
  [[ -d "${NTFS3G_RUNTIME}/bin" && -d "${NTFS3G_RUNTIME}/lib" ]] || {
    echo "invalid NTFS3G_RUNTIME: ${NTFS3G_RUNTIME}" >&2
    exit 2
  }
  mkdir -p "${BUILD_ROOT}/third-party/ntfs-3g"
  cp -R "${NTFS3G_RUNTIME}/." "${BUILD_ROOT}/third-party/ntfs-3g/"
else
  /bin/bash "${REPO_ROOT}/scripts/build-ntfs3g-runtime.sh" "${BUILD_ROOT}/third-party"
fi
cp "${BUILD_ROOT}/third-party/ntfs-3g/bin/"* "${RUNTIME_STAGE}/bin/"
cp "${BUILD_ROOT}/third-party/ntfs-3g/lib/"* "${RUNTIME_STAGE}/lib/"
cp -R "${BUILD_ROOT}/third-party/ntfs-3g/licenses" "${RUNTIME_STAGE}/licenses/ntfs-3g"
cp -R "${BUILD_ROOT}/third-party/ntfs-3g/source" "${RUNTIME_STAGE}/source"

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

xcrun swiftc -O -framework Security \
  "${CORE_SOURCES[@]}" \
  "${REPO_ROOT}/product/EDPNTFSWriteSafety.swift" \
  "${REPO_ROOT}/product/EDPNTFSMountPolicy.swift" \
  "${REPO_ROOT}/product/EDPNativeSystem.swift" \
  "${REPO_ROOT}/product/EDPVaultRuntime.swift" \
  -o "${RUNTIME_STAGE}/bin/edp-vaultctl"

xcrun swiftc -O -emit-library -module-name EDPReadWriteBridge \
  -Xlinker -install_name -Xlinker @rpath/libEDPReadWriteBridge.dylib \
  "${CORE_SOURCES[@]}" \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/EDPReadWriteBlockCBridge.swift" \
  -o "${RUNTIME_STAGE}/bin/libEDPReadWriteBridge.dylib"

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
# shellcheck disable=SC2086
/usr/bin/cc "${REPO_ROOT}/native/EDPFSKitPoC/Tools/EDPReadWriteFuseBridge.c" \
  -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} \
  "${RUNTIME_STAGE}/bin/libEDPReadWriteBridge.dylib" \
  -Wl,-rpath,@loader_path \
  -o "${RUNTIME_STAGE}/bin/edp-readwrite-fuse"

/usr/bin/clang -fobjc-arc -fblocks \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/DiskImages2Attach.m" \
  -framework Foundation \
  -o "${RUNTIME_STAGE}/bin/diskimages2-attach"

for item in "${RUNTIME_STAGE}/bin/"* "${RUNTIME_STAGE}/lib/"*; do
  /usr/bin/codesign --force --sign - "${item}"
done

/usr/bin/curl --fail --location --output \
  "${RUNTIME_STAGE}/licenses/macfuse/LICENSE.txt" \
  "https://raw.githubusercontent.com/macfuse/macfuse/macfuse-5.3.3/LICENSE.txt"
printf '%s  %s\n' \
  1201956ec47b2c53c4c4fe7751be6d6f55fefcc44a6eca08780a94e009bcdbcd \
  "${RUNTIME_STAGE}/licenses/macfuse/LICENSE.txt" \
  | /usr/bin/shasum -a 256 -c -

PAYLOAD="${BUILD_ROOT}/payload"
PRODUCT_DIR="${PAYLOAD}/Library/Application Support/EDP USB Vault"
mkdir -p "${PRODUCT_DIR}" "${PAYLOAD}/Library/LaunchDaemons" \
  "${PAYLOAD}/usr/local/bin"
cp -R "${RUNTIME_STAGE}/." "${PRODUCT_DIR}/"
ln -s "/Library/Application Support/EDP USB Vault/bin/edp-vaultctl" \
  "${PAYLOAD}/usr/local/bin/edp-vaultctl"

cat > "${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.edp.usbvault.mountd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Library/Application Support/EDP USB Vault/bin/edp-vaultctl</string>
    <string>daemon</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/var/log/edp-usbvault.log</string>
  <key>StandardErrorPath</key><string>/var/log/edp-usbvault.log</string>
</dict>
</plist>
PLIST
chmod 0644 "${PAYLOAD}/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"

SCRIPTS="${BUILD_ROOT}/scripts"
mkdir -p "${SCRIPTS}"
cat > "${SCRIPTS}/preinstall" <<'PREINSTALL'
#!/bin/bash
set -e
/bin/launchctl bootout system/com.edp.usbvault.mountd >/dev/null 2>&1 || true
OLD_CTL="/Library/Application Support/EDP USB Vault/bin/edp-vaultctl"
if [[ -x "${OLD_CTL}" ]]; then
  "${OLD_CTL}" cleanup >/dev/null 2>&1 || true
fi
exit 0
PREINSTALL
cat > "${SCRIPTS}/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -e
ROOT="/Library/Application Support/EDP USB Vault"
PLIST="/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
/usr/bin/chown -R root:wheel "${ROOT}"
/bin/chmod -R go-w "${ROOT}"
/bin/chmod 0755 "${ROOT}" "${ROOT}/bin" "${ROOT}/lib"
/bin/chmod 0755 "${ROOT}/bin/"*
/bin/chmod 0644 "${ROOT}/lib/"*
/usr/bin/xattr -dr com.apple.quarantine "${ROOT}" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "${PLIST}"
/bin/launchctl enable system/com.edp.usbvault.mountd || true
/bin/launchctl kickstart -k system/com.edp.usbvault.mountd || true
exit 0
POSTINSTALL
chmod 0755 "${SCRIPTS}/preinstall" "${SCRIPTS}/postinstall"

APP_COMPONENT="${BUILD_ROOT}/components/ZZ-EDP-USB-Vault.pkg"
mkdir -p "${BUILD_ROOT}/components"
/usr/bin/pkgbuild \
  --root "${PAYLOAD}" \
  --identifier com.edp.usbvault.runtime \
  --version "${VERSION}" \
  --install-location / \
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
echo "NTFS3G_VERSION=2026.7.7"
echo "RESULT=EDP_CLEAN_COMBINED_INSTALLER_BUILT"
