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
  echo "EDP USB Vault usbcore not found after installation: $USB_CORE" >&2
  echo "Installed EDP app candidates:" >&2
  /usr/bin/find /Applications -maxdepth 2 -name 'EDP USB Vault.app' -print >&2 || true
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

# Stage the app under its final absolute location, then ask pkgbuild to analyze that
# root. This lets us explicitly disable bundle relocation. Without this, PackageKit
# may discover a development copy with the same bundle id elsewhere on disk and
# install there instead of /Applications.
APP_ROOT="$WORK/app-root"
mkdir -p "$APP_ROOT/Applications"
/usr/bin/ditto "$APP_PATH" "$APP_ROOT/Applications/EDP USB Vault.app"

APP_COMPONENT_PLIST="$WORK/app-component.plist"
pkgbuild --analyze --root "$APP_ROOT" "$APP_COMPONENT_PLIST"
python3 - "$APP_COMPONENT_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

p = Path(sys.argv[1])
with p.open('rb') as f:
    items = plistlib.load(f)
if not items:
    raise SystemExit('pkgbuild produced an empty component plist')
found = False
for item in items:
    path = item.get('RootRelativeBundlePath', '')
    if path.endswith('EDP USB Vault.app'):
        item['BundleIsRelocatable'] = False
        item['BundleOverwriteAction'] = 'upgrade'
        found = True
if not found:
    raise SystemExit('EDP USB Vault.app was not found in pkgbuild component analysis')
with p.open('wb') as f:
    plistlib.dump(items, f, sort_keys=False)

with p.open('rb') as f:
    checked = plistlib.load(f)
entry = next(x for x in checked if x.get('RootRelativeBundlePath', '').endswith('EDP USB Vault.app'))
if entry.get('BundleIsRelocatable') is not False:
    raise SystemExit('BundleIsRelocatable is not false')
print('Verified component policy: EDP app is non-relocatable')
PY

APP_COMPONENT="$WORK/EDP-USB-Vault-App.pkg"
pkgbuild \
  --root "$APP_ROOT" \
  --component-plist "$APP_COMPONENT_PLIST" \
  --install-location / \
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

# Do not expose the PKG directly to Finder/Installer.app. macOS can ask Installer.app
# for Downloads/Desktop TCC access even when the PKG is opened from a DMG whose backing
# image lives in Downloads. Instead, ship a self-contained AppleScript launcher app.
# The launcher copies its embedded PKG to /private/tmp, then invokes the command-line
# /usr/sbin/installer with administrator privileges. Installer.app is never launched.
DMG_STAGE="$WORK/dmg-stage"
mkdir -p "$DMG_STAGE"
LAUNCHER_APP="$DMG_STAGE/安装 EDP USB Vault.app"
LAUNCHER_SOURCE="$WORK/installer-launcher.applescript"
TEMP_PKG="/private/tmp/com.edp.usbvault-installer.pkg"

cat > "$LAUNCHER_SOURCE" <<APPLESCRIPT
on run
    set appBundle to POSIX path of (path to me)
    set pkgPath to appBundle & "Contents/Resources/${PKG_NAME}"
    set tempPkg to "${TEMP_PKG}"

    try
        display dialog "将安装 EDP USB Vault、macFUSE 5.3.3 和后台服务。安装过程中会要求输入 Mac 管理员密码。" buttons {"取消", "安装"} default button "安装" cancel button "取消" with title "EDP USB Vault" with icon note

        do shell script "/bin/rm -f " & quoted form of tempPkg & "; /usr/bin/ditto " & quoted form of pkgPath & " " & quoted form of tempPkg

        set installCommand to "/usr/sbin/installer -pkg " & quoted form of tempPkg & " -target /; status=\\$?; /bin/rm -f " & quoted form of tempPkg & "; exit \\$status"
        do shell script installCommand with administrator privileges

        set answer to display dialog "EDP USB Vault 已安装完成。首次使用请在“系统设置 → 隐私与安全性 → 完整磁盘访问权限”中允许 EDP USB Vault。" buttons {"稍后", "打开 EDP USB Vault"} default button "打开 EDP USB Vault" with title "安装完成" with icon note
        if button returned of answer is "打开 EDP USB Vault" then
            do shell script "/usr/bin/open -a " & quoted form of "/Applications/EDP USB Vault.app"
        end if
    on error errMsg number errNum
        try
            do shell script "/bin/rm -f " & quoted form of tempPkg
        end try
        if errNum is not -128 then
            display dialog "安装失败：" & errMsg buttons {"关闭"} default button "关闭" with title "EDP USB Vault" with icon stop
        end if
    end try
end run
APPLESCRIPT

osacompile -o "$LAUNCHER_APP" "$LAUNCHER_SOURCE"
mkdir -p "$LAUNCHER_APP/Contents/Resources"
cp "$PKG_OUTPUT" "$LAUNCHER_APP/Contents/Resources/$PKG_NAME"

# Give the launcher a stable identity and reuse the product icon when available.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.edp.usbvault.installer" "$LAUNCHER_APP/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName 安装 EDP USB Vault" "$LAUNCHER_APP/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 安装 EDP USB Vault" "$LAUNCHER_APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 安装 EDP USB Vault" "$LAUNCHER_APP/Contents/Info.plist" || true
ICON_SOURCE="$(find "$APP_PATH/Contents/Resources" -maxdepth 1 -name '*.icns' -print -quit 2>/dev/null || true)"
if [[ -n "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$LAUNCHER_APP/Contents/Resources/EDPInstaller.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string EDPInstaller" "$LAUNCHER_APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile EDPInstaller" "$LAUNCHER_APP/Contents/Info.plist" || true
fi
codesign --force --deep --sign - "$LAUNCHER_APP"
codesign --verify --deep --strict --verbose=2 "$LAUNCHER_APP"

test -f "$LAUNCHER_APP/Contents/Resources/$PKG_NAME"
if find "$DMG_STAGE" -maxdepth 1 -name '*.pkg' | grep -q .; then
  echo "Refusing to build: top-level PKG would reintroduce Installer.app Downloads TCC" >&2
  exit 1
fi

cat > "$DMG_STAGE/安装说明.txt" <<'README'
EDP USB Vault 一体化安装

1. 双击“安装 EDP USB Vault.app”。
2. 点击“安装”，输入一次 Mac 管理员密码。
3. 安装完成后，在“系统设置 → 隐私与安全性 → 完整磁盘访问权限”中允许 EDP USB Vault。
4. 打开 EDP USB Vault，插入 U 盘即可使用。

安装器已经内置 EDP USB Vault、macFUSE 和后台服务。
安装过程不使用 macOS 图形化“安装器.app”，避免其额外申请“下载”文件夹访问权限。
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
