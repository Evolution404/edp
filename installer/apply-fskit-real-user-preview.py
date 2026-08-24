#!/usr/bin/env python3
"""Experimental FSKit bridge privilege split for local/CI validation.

Apply the existing hybrid preview first (root LaunchDaemon + gui bootstrap), then
refine only the bridge credentials:

  root daemon -> launchctl asuser <console uid> -> bridge starts as root
      -> bridge opens /dev/rdiskN
      -> bridge setgid/setuid to the console user
      -> libfuse/MFMount/FSKit runs as the real approved user

This deliberately remains a preview transformation until hardware testing proves
that macFUSE FSKit accepts this model. Run this script once after `git pull`
before a local build. It is idempotent.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(ROOT / "installer/apply-fskit-preview.py")], cwd=ROOT, check=True)

session = ROOT / "crates/usbcore/src/session.rs"
text = session.read_text()

old_helper = '''/// Console GUI uid used only to select the FSKit/Mach bootstrap namespace.
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
new_helper = '''/// Real console uid/gid. `launchctl asuser` selects this user's GUI bootstrap;
/// the bridge later drops its process credentials to the same identity, but only
/// after opening the raw disk while still privileged.
fn console_gui_identity() -> Option<(u32, u32)> {
    if unsafe { libc::geteuid() } != 0 {
        return None;
    }
    let output = Command::new("/usr/bin/stat")
        .args(["-f", "%u %g", "/dev/console"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let mut fields = text.split_whitespace();
    let uid = fields.next()?.parse::<u32>().ok()?;
    let gid = fields.next()?.parse::<u32>().ok()?;
    if uid == 0 {
        return None;
    }
    Some((uid, gid))
}
'''
if old_helper in text:
    text = text.replace(old_helper, new_helper, 1)
elif new_helper not in text:
    raise SystemExit("console GUI helper not found after base preview")

old_spawn = '''    let self_exe = std::env::current_exe()?;
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
'''
new_spawn = '''    let self_exe = std::env::current_exe()?;
    let bridge_gui_identity = console_gui_identity();
    let mut command = if let Some((uid, _gid)) = bridge_gui_identity {
        let mut command = Command::new("/bin/launchctl");
        command.arg("asuser").arg(uid.to_string()).arg(&self_exe);
        command
    } else {
        Command::new(&self_exe)
    };
    if let Some((uid, gid)) = bridge_gui_identity {
        command
            .env("EDP_BRIDGE_RUN_UID", uid.to_string())
            .env("EDP_BRIDGE_RUN_GID", gid.to_string());
    }
    info!(
        "bridge spawn: daemon_euid={} gui_identity={:?}; bridge will open raw disk before dropping credentials",
        unsafe { libc::geteuid() },
        bridge_gui_identity
    );
    let mut child = command
'''
if old_spawn in text:
    text = text.replace(old_spawn, new_spawn, 1)
elif new_spawn not in text:
    raise SystemExit("bridge spawn block not found after base preview")

# The bridge becomes an unprivileged user before its performance reporter starts,
# so keep the preview metrics outside the root-only session directory.
old_perf = '    let performance_path = session_dir.join("performance.json");'
new_perf = '''    let performance_path = PathBuf::from("/tmp")
        .join(format!("com.edp.usbvault-{session_id}-performance.json"));'''
if old_perf in text:
    text = text.replace(old_perf, new_perf, 1)
elif new_perf not in text:
    raise SystemExit("performance path snippet not found")

session.write_text(text)

# Keep installer-facing diagnostics accurate for this experiment.
installer = ROOT / "installer/build-one-click.sh"
installer_text = installer.read_text()
installer_text = installer_text.replace(
    "root daemon installed; FSKit bridge will enter gui/${CONSOLE_UID:-unknown} via launchctl asuser",
    "root daemon installed; bridge enters gui/${CONSOLE_UID:-unknown}, opens raw disk as root, then drops to the console user before FSKit",
)
installer_text = installer_text.replace(
    "后台服务保持管理员权限访问原始 U 盘，仅 macFUSE/FSKit 桥接进程进入当前用户会话。",
    "后台服务保持管理员权限；桥接进程先打开原始 U 盘，再降权为当前用户进入 macFUSE/FSKit。",
)
installer.write_text(installer_text)

print("Applied real-user FSKit preview: root raw-open -> setuid console user -> libfuse/FSKit")
