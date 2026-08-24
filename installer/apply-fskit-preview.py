#!/usr/bin/env python3
"""Apply preview-only FSKit installation adjustments.

The bridge transport uses macFUSE's official libfuse API directly. This patch:
1. moves the transient hidden bridge below /Volumes, which FSKit requires;
2. makes the one-click installer's postinstall explicitly register macFUSE's
   File System Extensions so they appear in System Settings on first install;
3. deliberately avoids --force. Re-registering an already registered FSKit
   extension can leave PluginKit/FSKit in a stale state until the FSKit
   subsystem is restarted.
"""
from pathlib import Path

session = Path("crates/usbcore/src/session.rs")
text = session.read_text()
old = '    let bridge_mount = session_dir.join("bridge");'
new = '    let bridge_mount = PathBuf::from("/Volumes").join(format!(".edp-bridge-{session_id}"));'
if old in text:
    session.write_text(text.replace(old, new, 1))
elif new not in text:
    raise SystemExit("expected bridge mountpoint snippet not found")

installer = Path("installer/build-one-click.sh")
text = installer.read_text()
needle = '''/bin/launchctl kickstart -k "system/${LABEL}" || true

exit 0
POSTINSTALL'''
replacement = '''/bin/launchctl kickstart -k "system/${LABEL}" || true

# Register macFUSE File System Extensions without forcing a re-registration.
# macFUSE will also try automatic registration at mount time, but doing it here
# makes the extension visible in System Settings before the first mount.
MACFUSE_CTL="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
if [[ -x "$MACFUSE_CTL" ]]; then
  echo "Registering macFUSE File System Extensions..."
  "$MACFUSE_CTL" install --components file-system-extensions || true
else
  echo "Warning: macFUSE control tool was not found at $MACFUSE_CTL" >&2
fi

exit 0
POSTINSTALL'''
if needle in text:
    text = text.replace(needle, replacement, 1)
elif 'install --components file-system-extensions || true' not in text:
    raise SystemExit("expected installer postinstall snippet not found")

old_dialog = 'EDP USB Vault 已安装完成。首次使用请在“系统设置 → 隐私与安全性 → 完整磁盘访问权限”中允许 EDP USB Vault。'
new_dialog = 'EDP USB Vault 已安装完成。首次使用请在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”中启用 macFUSE，并在“隐私与安全性 → 完整磁盘访问权限”中允许 EDP USB Vault。'
if old_dialog in text:
    text = text.replace(old_dialog, new_dialog, 1)

installer.write_text(text)

print("Applied installer-preview FSKit mountpoint and non-forced extension-registration patches")
