#!/usr/bin/env python3
"""Apply preview-only FSKit installation adjustments.

The FSKit backend is approved per logged-in user session. Running the whole
mount path from a root LaunchDaemon makes MFMount see the extension as disabled
even when System Settings shows macFUSE enabled. This preview therefore:
1. moves the hidden bridge below /Volumes (FSKit requirement);
2. moves the installer-managed daemon from system LaunchDaemon to the current
   user's LaunchAgent so bridge/libfuse/MFMount run in the approved GUI session;
3. uses a per-user /tmp RPC socket because a LaunchAgent cannot create sockets
   directly under /var/run;
4. registers macFUSE file-system extensions in the same user bootstrap domain
   without forcing re-registration.
"""
from pathlib import Path
import re


def replace_once(path: Path, old: str, new: str, description: str) -> None:
    text = path.read_text()
    if old in text:
        path.write_text(text.replace(old, new, 1))
        return
    if new in text:
        return
    raise SystemExit(f"expected {description} snippet not found in {path}")


# FSKit only supports mount points below /Volumes.
session = Path("crates/usbcore/src/session.rs")
replace_once(
    session,
    '    let bridge_mount = session_dir.join("bridge");',
    '    let bridge_mount = PathBuf::from("/Volumes").join(format!(".edp-bridge-{session_id}"));',
    "bridge mountpoint",
)

# usbcore CLI/daemon default socket becomes per-user. The installer LaunchAgent
# exports the same value explicitly, and the GUI computes the same path.
main = Path("crates/usbcore/src/main.rs")
replace_once(
    main,
    '        .unwrap_or_else(|| "/var/run/com.edp.usbvault.daemon.sock".to_string())',
    '        .unwrap_or_else(|| format!("/tmp/com.edp.usbvault.daemon.{}.sock", unsafe { libc::geteuid() }))',
    "usbcore daemon socket",
)

config = Path("crates/usbcore/src/daemon/config.rs")
replace_once(
    config,
    '            socket_path: "/var/run/com.edp.usbvault.daemon.sock".to_string(),',
    '            socket_path: format!("/tmp/com.edp.usbvault.daemon.{}.sock", unsafe { libc::geteuid() }),',
    "daemon config socket",
)

# Tauri backend connects to the same per-user socket.
gui = Path("gui/src-tauri/src/lib.rs")
text = gui.read_text()
old_const = 'const SOCKET_PATH: &str = "/var/run/com.edp.usbvault.daemon.sock";\n'
new_fn = '''fn default_socket_path() -> String {
    let uid = std::process::Command::new("/usr/bin/id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "0".to_string());
    format!("/tmp/com.edp.usbvault.daemon.{uid}.sock")
}
'''
if old_const in text:
    text = text.replace(old_const, new_fn, 1)
elif new_fn not in text:
    raise SystemExit("expected GUI socket constant not found")
old_rpc = '            .unwrap_or_else(|| SOCKET_PATH.to_string())'
new_rpc = '            .unwrap_or_else(default_socket_path)'
if old_rpc in text:
    text = text.replace(old_rpc, new_rpc, 1)
elif new_rpc not in text:
    raise SystemExit("expected GUI Rpc socket fallback not found")
gui.write_text(text)

# GUI service status must recognize the installer-managed user LaunchAgent.
service = Path("gui/src-tauri/src/service_management.rs")
text = service.read_text()
text = text.replace(
    '    const LEGACY_LABEL: &str = "system/com.edp.usbvault.daemon.v2";',
    '    const LABEL: &str = "com.edp.usbvault.daemon.v2";',
    1,
)
old_status_fn = '''    fn installer_daemon_enabled() -> bool {
        Command::new("/bin/launchctl")
            .args(["print", LEGACY_LABEL])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }
'''
new_status_fn = '''    fn installer_daemon_enabled() -> bool {
        let uid = Command::new("/usr/bin/id")
            .arg("-u")
            .output()
            .ok()
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let mut targets = vec![format!("system/{LABEL}")];
        if let Some(uid) = uid {
            targets.insert(0, format!("gui/{uid}/{LABEL}"));
        }
        targets.into_iter().any(|target| {
            Command::new("/bin/launchctl")
                .arg("print")
                .arg(target)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|status| status.success())
                .unwrap_or(false)
        })
    }
'''
if old_status_fn in text:
    text = text.replace(old_status_fn, new_status_fn, 1)
elif new_status_fn not in text:
    raise SystemExit("expected installer service detection function not found")
service.write_text(text)

# Replace the generated package postinstall wholesale. It removes the previous
# root LaunchDaemon, transfers daemon state to the console user, installs a
# per-user LaunchAgent, and registers macFUSE in the user's bootstrap domain.
installer = Path("installer/build-one-click.sh")
text = installer.read_text()
start = "cat > \"$SCRIPTS/postinstall\" <<'POSTINSTALL'\n"
end = "POSTINSTALL\nchmod 0755 \"$SCRIPTS/postinstall\""
start_i = text.find(start)
end_i = text.find(end, start_i + len(start))
if start_i < 0 or end_i < 0:
    raise SystemExit("postinstall heredoc not found")

postinstall = r'''cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -euo pipefail

LABEL="com.edp.usbvault.daemon.v2"
USB_CORE="/Applications/EDP USB Vault.app/Contents/Resources/usbcore"
DATA_ROOT="/var/db/com.edp.usbvault"
OLD_SYSTEM_PLIST="/Library/LaunchDaemons/${LABEL}.plist"

if [[ ! -x "$USB_CORE" ]]; then
  echo "EDP USB Vault usbcore not found after installation: $USB_CORE" >&2
  exit 1
fi

CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  echo "No logged-in console user; cannot install FSKit user agent" >&2
  exit 1
fi
CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
CONSOLE_GID="$(/usr/bin/id -g "$CONSOLE_USER")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
if [[ -z "$USER_HOME" ]]; then
  USER_HOME="/Users/${CONSOLE_USER}"
fi
AGENT_DIR="${USER_HOME}/Library/LaunchAgents"
AGENT_PLIST="${AGENT_DIR}/${LABEL}.plist"
SOCKET="/tmp/com.edp.usbvault.daemon.${CONSOLE_UID}.sock"

# Remove the previous root/system fallback before starting the user-session agent.
/bin/launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
/bin/launchctl bootout system "$OLD_SYSTEM_PLIST" >/dev/null 2>&1 || true
/bin/rm -f "$OLD_SYSTEM_PLIST" /var/run/com.edp.usbvault.daemon.sock "$SOCKET"

# Keep existing credentials/config across preview upgrades, but make the daemon
# state writable by the logged-in account that owns the FSKit approval.
/bin/mkdir -p "$DATA_ROOT/sessions" "$AGENT_DIR"
/usr/sbin/chown -R "${CONSOLE_UID}:${CONSOLE_GID}" "$DATA_ROOT" "$AGENT_DIR"
/bin/chmod 0700 "$DATA_ROOT" "$DATA_ROOT/sessions"

cat > "$AGENT_PLIST" <<PLIST_EOF
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
  <key>EnvironmentVariables</key>
  <dict>
    <key>EDP_USB_SOCKET</key>
    <string>${SOCKET}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>/tmp/com.edp.usbvault.daemon.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/com.edp.usbvault.daemon.stderr.log</string>
</dict>
</plist>
PLIST_EOF
/usr/sbin/chown "${CONSOLE_UID}:${CONSOLE_GID}" "$AGENT_PLIST"
/bin/chmod 0644 "$AGENT_PLIST"

# Register macFUSE in the same GUI bootstrap/user context in which bridge mounts run.
MACFUSE_CTL="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
if [[ -x "$MACFUSE_CTL" ]]; then
  echo "Registering macFUSE File System Extensions for ${CONSOLE_USER}..."
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
    "$MACFUSE_CTL" install --components file-system-extensions || true
fi

/bin/launchctl bootout "gui/${CONSOLE_UID}/${LABEL}" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/${CONSOLE_UID}" "$AGENT_PLIST"
/bin/launchctl enable "gui/${CONSOLE_UID}/${LABEL}" || true
/bin/launchctl kickstart -k "gui/${CONSOLE_UID}/${LABEL}" || true

echo "EDP USB Vault user LaunchAgent installed for ${CONSOLE_USER} (uid ${CONSOLE_UID})"
exit 0
POSTINSTALL
chmod 0755 "$SCRIPTS/postinstall"'''
text = text[:start_i] + postinstall + text[end_i + len(end):]

old_dialog = 'EDP USB Vault 已安装完成。首次使用请在“系统设置 → 隐私与安全性 → 完整磁盘访问权限”中允许 EDP USB Vault。'
new_dialog = 'EDP USB Vault 已安装完成。首次使用请启用 macFUSE 文件系统扩展，并在“系统设置 → 隐私与安全性 → 完整磁盘访问权限”中允许 EDP USB Vault。后台服务已改为当前用户会话运行，以兼容 FSKit。'
text = text.replace(old_dialog, new_dialog)
installer.write_text(text)

print("Applied FSKit preview: /Volumes bridge + per-user LaunchAgent + per-user RPC socket")
