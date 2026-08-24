#!/bin/bash
set -euo pipefail

APP_PATH="${1:?usage: build-one-click.sh <app-path> <output-dir> <macfuse-dmg>}"
OUTPUT_DIR="${2:?missing output dir}"
MACFUSE_DMG="${3:?missing macFUSE dmg}"
APP_VERSION="${APP_VERSION:-0.0.0}"
BUILD_ARCH="${BUILD_ARCH:-arm64}"
LABEL="com.edp.usbvault.daemon.v2"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$MACFUSE_DMG" ]]; then
  echo "macFUSE dmg not found: $MACFUSE_DMG" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/edp-installer.XXXXXX")"
MOUNT_POINT="$WORK/macfuse-volume"
cleanup() {
  if mount | grep -Fq " on $MOUNT_POINT "; then
    hdiutil detach -quiet "$MOUNT_POINT" || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

SCRIPTS="$WORK/scripts"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -euo pipefail

LABEL="com.edp.usbvault.daemon.v2"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
USB_CORE="/Applications/EDP USB Vault.app/Contents/Resources/usbcore"

if [[ ! -x "$USB_CORE" ]]; then
  echo "EDP USB Vault usbcore not found: $USB_CORE" >&2
  exit 1
fi

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${USB_CORE}</string>
    <string>daemon</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

/bin/launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$PLIST"
/bin/launchctl enable "system/${LABEL}" || true
/bin/launchctl kickstart -k "system/${LABEL}" || true

exit 0
POSTINSTALL
chmod 0755 "$SCRIPTS/postinstall"

APP_COMPONENT="$WORK/EDP-USB-Vault-App.pkg"
pkgbuild \
  --component "$APP_PATH" \
  --install-location /Applications \
  --identifier com.edp.usbvault.app-package \
  --version "$APP_VERSION" \
  --scripts "$SCRIPTS" \
  "$APP_COMPONENT"

mkdir -p "$MOUNT_POINT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$MACFUSE_DMG"
MACFUSE_PRODUCT="$(find "$MOUNT_POINT" -maxdepth 2 -name 'Install macFUSE*.pkg' -print -quit)"
if [[ -z "$MACFUSE_PRODUCT" ]]; then
  MACFUSE_PRODUCT="$(find "$MOUNT_POINT" -maxdepth 2 -name '*.pkg' -print -quit)"
fi
if [[ -z "$MACFUSE_PRODUCT" ]]; then
  echo "Could not find macFUSE installer package in $MACFUSE_DMG" >&2
  exit 1
fi

# macFUSE's outer product archive contains component packages. `pkgutil --expand`
# represents nested packages as directory archives on recent macOS runners; feeding
# those PKFolderArchive directories directly to productbuild can crash PackageKit.
# Re-flatten every directory-form component before composing our product.
MACFUSE_EXPANDED="$WORK/macfuse-expanded"
pkgutil --expand "$MACFUSE_PRODUCT" "$MACFUSE_EXPANDED"
COMPONENT_DIR="$WORK/components"
mkdir -p "$COMPONENT_DIR"

component_count=0
while IFS= read -r -d '' pkg; do
  name="$(basename "$pkg")"
  dest="$COMPONENT_DIR/$(printf '%02d-%s' "$component_count" "$name")"
  if [[ -d "$pkg" ]]; then
    pkgutil --flatten "$pkg" "$dest"
  else
    cp "$pkg" "$dest"
  fi
  echo "Prepared macFUSE component: $(basename "$dest")"
  pkgutil --check-signature "$dest" || true
  component_count=$((component_count + 1))
done < <(find "$MACFUSE_EXPANDED" -maxdepth 3 -name '*.pkg' -print0)

if [[ "$component_count" -eq 0 ]]; then
  echo "macFUSE product did not expose component packages after pkgutil --expand" >&2
  find "$MACFUSE_EXPANDED" -maxdepth 3 -print >&2 || true
  exit 1
fi

cp "$APP_COMPONENT" "$COMPONENT_DIR/99-EDP-USB-Vault-App.pkg"

DIST="$WORK/Distribution.xml"
args=(--synthesize)
while IFS= read -r -d '' pkg; do
  args+=(--package "$pkg")
done < <(find "$COMPONENT_DIR" -maxdepth 1 -name '*.pkg' -print0 | sort -z)
productbuild "${args[@]}" "$DIST"

python3 - "$DIST" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '<installer-gui-script minSpecVersion="1">'
if needle in s and '<title>' not in s:
    s = s.replace(needle, needle + '\n    <title>EDP USB Vault</title>', 1)
p.write_text(s)
PY

PKG_NAME="EDP-USB-Vault-${APP_VERSION}-${BUILD_ARCH}-Installer.pkg"
PKG_OUTPUT="$WORK/$PKG_NAME"
productbuild \
  --distribution "$DIST" \
  --package-path "$COMPONENT_DIR" \
  "$PKG_OUTPUT"

pkgutil --check-signature "$PKG_OUTPUT" || true

# Ship the PKG inside a read-only DMG. When users run a PKG directly from Desktop,
# macOS may ask Installer.app for Desktop-folder access; denying that prompt makes
# installation fail before our package runs. A mounted DMG avoids that unrelated
# TCC prompt and gives first-time users a deterministic entry point.
DMG_STAGE="$WORK/dmg-stage"
mkdir -p "$DMG_STAGE"
cp "$PKG_OUTPUT" "$DMG_STAGE/$PKG_NAME"
cat > "$DMG_STAGE/安装说明.txt" <<'README'
EDP USB Vault 安装

1. 双击 “EDP-USB-Vault-*-Installer.pkg”。
2. 按 macOS 安装器提示输入管理员密码并完成安装。
3. 如 macOS 要求批准 macFUSE 系统组件，请按系统提示批准并在要求时重启。
4. 安装完成后，从“应用程序”打开 EDP USB Vault。

本安装包同时包含 EDP USB Vault、macFUSE 和后台服务。
README

DMG_NAME="EDP-USB-Vault-${APP_VERSION}-${BUILD_ARCH}-Installer.dmg"
DMG_OUTPUT="$OUTPUT_DIR/$DMG_NAME"
hdiutil create -quiet -ov -format UDZO \
  -volname "EDP USB Vault Installer" \
  -srcfolder "$DMG_STAGE" \
  "$DMG_OUTPUT"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" > "SHA256SUMS-installer-${BUILD_ARCH}.txt"
)
echo "Built: $DMG_OUTPUT"
