#!/usr/bin/env python3
"""Apply preview-only FSKit hybrid-privilege adjustments.

macFUSE's FSKit backend needs the caller to live in the logged-in GUI bootstrap
where the file-system extension is approved. Raw /dev/rdisk access, however,
needs the privileged daemon. The preview therefore keeps usbcore as a root
LaunchDaemon and launches only the bridge through `launchctl asuser`.

`launchctl asuser` adopts the target user's Mach bootstrap/audit session but does
not change process credentials. The bridge consequently remains uid 0 (raw disk
access) while MFMount/FSKit resolves services in the console user's GUI session.
"""
from pathlib import Path


def replace_once(path: Path, old: str, new: str, description: str) -> None:
    text = path.read_text()
    if old in text:
        path.write_text(text.replace(old, new, 1))
        return
    if new in text:
        return
    raise SystemExit(f"expected {description} snippet not found in {path}")


# FSKit supports mount points only below /Volumes.
session = Path("crates/usbcore/src/session.rs")
replace_once(
    session,
    '    let bridge_mount = session_dir.join("bridge");',
    '    let bridge_mount = PathBuf::from("/Volumes").join(format!(".edp-bridge-{session_id}"));',
    "bridge mountpoint",
)

# Root daemon discovers the console uid and runs the bridge in that GUI bootstrap.
text = session.read_text()
helper_anchor = '''fn kill(pid: u32, sig: i32) -> std::io::Result<()> {
    let r = unsafe { libc::kill(pid as libc::pid_t, sig) };
    if r != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}
'''
helper = helper_anchor + '''
/// Console GUI uid used only to select the FSKit/Mach bootstrap namespace.
/// `launchctl asuser` deliberately keeps the caller's uid/gid unchanged.
fn console_gui_uid() -> Option<u32> {
    if unsafe { libc::geteuid() } != 0 {
        return None;
    }
    let output = Command::new("/usr/bin/stat")
        .args(["-f", "%u", "/dev/console"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let uid = String::from_utf8(output.stdout).ok()?.trim().parse::<u32>().ok()?;
    (uid != 0).then_some(uid)
}
'''
if helper not in text:
    if helper_anchor not in text:
        raise SystemExit("expected kill helper anchor not found")
    text = text.replace(helper_anchor, helper, 1)

old_spawn = '''    let self_exe = std::env::current_exe()?;
    let mut child = Command::new(&self_exe)
        .arg("bridge")
'''
new_spawn = '''    let self_exe = std::env::current_exe()?;
    let bridge_gui_uid = console_gui_uid();
    let mut command = if let Some(uid) = bridge_gui_uid {
        let mut command = Command::new("/bin/launchctl");
        command.arg("asuser").arg(uid.to_string()).arg(&self_exe);
        command
    } else {
        Command::new(&self_exe)
    };
    info!(
        "bridge spawn: euid={} gui_bootstrap_uid={:?}",
        unsafe { libc::geteuid() },
        bridge_gui_uid
    );
    let mut child = command
        .arg("bridge")
'''
if old_spawn in text:
    text = text.replace(old_spawn, new_spawn, 1)
elif new_spawn not in text:
    raise SystemExit("expected bridge spawn snippet not found")
session.write_text(text)

# A previous preview persisted a per-user /tmp socket in config.json. Migrate it
# back to the root LaunchDaemon socket while preserving all other configuration.
daemon = Path("crates/usbcore/src/daemon.rs")
text = daemon.read_text()
old_load = '''    let mut cfg = config::load(&config_path)?;
    // Persist schema migration immediately. Test-only socket overrides are applied
'''
new_load = '''    let mut cfg = config::load(&config_path)?;
    if cfg.socket_path.starts_with("/tmp/com.edp.usbvault.daemon.") {
        cfg.socket_path = "/var/run/com.edp.usbvault.daemon.sock".to_string();
    }
    // Persist schema migration immediately. Test-only socket overrides are applied
'''
if old_load in text:
    text = text.replace(old_load, new_load, 1)
elif new_load not in text:
    raise SystemExit("expected daemon config load snippet not found")
daemon.write_text(text)

# Install a root LaunchDaemon again, remove the previous per-user preview agent,
# and register macFUSE's FSKit extension in the console user's GUI context.
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
SYSTEM_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
USB_CORE="/Applications/EDP USB Vault.app/Contents/Resources/usbcore"
DATA_ROOT="/var/db/com.edp.usbvault"

if [[ ! -x "$USB_CORE" ]]; then
  echo "EDP USB Vault usbcore not found after installation: $USB_CORE" >&2
  exit 1
fi

CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
CONSOLE_UID=""
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"

  # Remove the previous all-user LaunchAgent preview before restoring the root daemon.
  OLD_AGENT="/Users/${CONSOLE_USER}/Library/LaunchAgents/${LABEL}.plist"
  /bin/launchctl bootout "gui/${CONSOLE_UID}/${LABEL}" >/dev/null 2>&1 || true
  /bin/launchctl bootout "gui/${CONSOLE_UID}" "$OLD_AGENT" >/dev/null 2>&1 || true
  /bin/rm -f "$OLD_AGENT" "/tmp/com.edp.usbvault.daemon.${CONSOLE_UID}.sock"
fi

/bin/mkdir -p "$DATA_ROOT/sessions"
/usr/sbin/chown -R root:wheel "$DATA_ROOT"
/bin/chmod 0700 "$DATA_ROOT" "$DATA_ROOT/sessions"

cat > "$SYSTEM_PLIST" <<PLIST_EOF
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
/usr/sbin/chown root:wheel "$SYSTEM_PLIST"
/bin/chmod 0644 "$SYSTEM_PLIST"

# Register/refresh the FSKit extension in the logged-in user's bootstrap. Do not
# force re-registration; that can leave PluginKit/FSKit stale until restart.
MACFUSE_CTL="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
if [[ -n "$CONSOLE_UID" && -x "$MACFUSE_CTL" ]]; then
  echo "Registering macFUSE File System Extensions for ${CONSOLE_USER}..."
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
    "$MACFUSE_CTL" install --components file-system-extensions || true
fi

/bin/rm -f /var/run/com.edp.usbvault.daemon.sock
/bin/launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$SYSTEM_PLIST"
/bin/launchctl enable "system/${LABEL}" || true
/bin/launchctl kickstart -k "system/${LABEL}" || true

echo "EDP USB Vault root daemon installed; FSKit bridge will enter gui/${CONSOLE_UID:-unknown} via launchctl asuser"
exit 0
POSTINSTALL
chmod 0755 "$SCRIPTS/postinstall"'''
text = text[:start_i] + postinstall + text[end_i + len(end):]

old_dialog = 'EDP USB Vault 已安装完成。首次使用请启用 macFUSE 文件系统扩展，并在“系统设置 → 隐私与安全性 → 完整磁盘访问权限”中允许 EDP USB Vault。后台服务已改为当前用户会话运行，以兼容 FSKit。'
new_dialog = 'EDP USB Vault 已安装完成。后台服务保持管理员权限访问原始 U 盘，仅 macFUSE/FSKit 桥接进程进入当前用户会话。请保持 macFUSE 文件系统扩展为启用状态。'
text = text.replace(old_dialog, new_dialog)
installer.write_text(text)

print("Applied FSKit hybrid preview: root daemon + root bridge in console GUI bootstrap")
