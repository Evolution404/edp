#!/usr/bin/env python3
"""Experimental FSKit privilege split for hardware validation.

Target model:

  root LaunchDaemon
      -> opens /dev/rdiskN while privileged
      -> clears FD_CLOEXEC on that already-open raw-device descriptor
      -> launchctl asuser <console uid>
      -> launchctl itself is exec'd as the console uid/gid
      -> usbcore bridge therefore starts life as the real logged-in user
      -> bridge consumes the inherited raw-device FD instead of reopening /dev/rdiskN
      -> libfuse/MFMount/FSKit sees a genuine user process from exec start

This is intentionally a preview transformation until real hardware testing proves
macFUSE FSKit accepts the model. Run once after `git pull` before a local build.
The script is idempotent.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(ROOT / "installer/apply-fskit-preview.py")], cwd=ROOT, check=True)

# ---------------------------------------------------------------------------
# usbcore CLI: allow the hidden bridge command to receive an inherited source FD
# ---------------------------------------------------------------------------
main = ROOT / "crates/usbcore/src/main.rs"
text = main.read_text()

old = '''        #[arg(long)]
        key_fd: i32,
        #[arg(long)]
        readonly: bool,
'''
new = '''        #[arg(long)]
        key_fd: i32,
        /// 已由特权父进程打开并继承的 raw source FD；存在时 bridge 不再 open(source)。
        #[arg(long)]
        source_fd: Option<i32>,
        #[arg(long)]
        readonly: bool,
'''
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("bridge source_fd CLI anchor not found")

old = '''            partition_type,
            key_fd,
            readonly,
            ready_fd,
'''
new = '''            partition_type,
            key_fd,
            source_fd,
            readonly,
            ready_fd,
'''
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("bridge match source_fd anchor not found")

old = '''            partition_type,
            key_fd,
            readonly,
            ready_fd,
            performance_path.as_deref(),
'''
new = '''            partition_type,
            key_fd,
            source_fd,
            readonly,
            ready_fd,
            performance_path.as_deref(),
'''
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("bridge::run source_fd anchor not found")

main.write_text(text)

# ---------------------------------------------------------------------------
# bridge: consume inherited FD; do not change credentials after process start
# ---------------------------------------------------------------------------
bridge = ROOT / "crates/usbcore/src/bridge.rs"
text = bridge.read_text()

helper_start = text.find("/// Preview-only bridge identity")
run_marker = text.find("#[allow(clippy::too_many_arguments)]", helper_start)
if helper_start >= 0 and run_marker > helper_start:
    helper = '''/// Open the source through an inherited descriptor when supplied by the root daemon.
/// The bridge process itself is already the logged-in user from exec start.
fn open_source_io(source: &Path, readonly: bool, source_fd: Option<i32>) -> anyhow::Result<FileRawIo> {
    if let Some(fd) = source_fd {
        if fd < 0 {
            bail!("source_fd 非法: {fd}");
        }
        use std::os::unix::io::FromRawFd;
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        return FileRawIo::from_open_file(file, source)
            .with_context(|| format!("使用继承 source_fd={fd} 打开 {}", source.display()));
    }
    FileRawIo::open(source, readonly)
        .with_context(|| format!("直接打开 source {}", source.display()))
}

'''
    text = text[:helper_start] + helper + text[run_marker:]
elif "fn open_source_io(" not in text:
    raise SystemExit("bridge identity helper block not found")

old = '''    partition_type: u32,
    key_fd: i32,
    readonly: bool,
'''
new = '''    partition_type: u32,
    key_fd: i32,
    source_fd: Option<i32>,
    readonly: bool,
'''
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("bridge run source_fd signature anchor not found")

block_start = text.find("    // IMPORTANT: open the raw device while still privileged.")
info_start = text.find("    info!(", block_start)
info_end = text.find("    );", info_start)
if block_start >= 0 and info_start > block_start and info_end > info_start:
    replacement = '''    // The root daemon already performed open(2). This process starts as the
    // real console user and only consumes the inherited descriptor.
    let process_euid = unsafe { libc::geteuid() };
    let process_egid = unsafe { libc::getegid() };
    let io = Arc::new(open_source_io(source, readonly, source_fd)?);
    let volume = Arc::new(EncryptedPartitionIO::open(io, desc, readonly)?);
    std::fs::create_dir_all(mountpoint)?;

    info!(
        "bridge(libfuse/FSKit): source={} mount={} start_sector={start_sector} size={size_bytes} priority_raised={priority_raised} process_euid={process_euid} process_egid={process_egid} inherited_source_fd={:?}",
        source.display(),
        mountpoint.display(),
        source_fd
    );'''
    text = text[:block_start] + replacement + text[info_end + len("    );"):]
elif "inherited_source_fd={:?}" not in text:
    raise SystemExit("bridge root-open/drop block not found")

# Update stale module-level explanation if present.
text = text.replace(
    "//! root LaunchDaemon 启动 bridge 时，bridge 会先以 root 身份打开 `/dev/rdiskN`，\n//! 然后在进入 libfuse/FSKit 前真正降权到当前控制台用户。已经打开的原始磁盘\n//! FD 在降权后继续有效，因此可以同时满足原始磁盘访问和 FSKit 用户授权模型。\n",
    "//! root LaunchDaemon 先打开 `/dev/rdiskN`，再把该 FD 继承给从 exec 开始就\n//! 以当前控制台用户身份运行的 bridge。bridge 不重新打开设备，只使用继承 FD，\n//! 从而把 raw-disk 权限与 MFMount/FSKit 用户授权上下文彻底分离。\n",
)
bridge.write_text(text)

# ---------------------------------------------------------------------------
# session: root-open source, make descriptor inheritable, then exec launchctl as user
# ---------------------------------------------------------------------------
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
new_helper = '''/// Current console user's real uid/gid. The bridge must be exec'd with this
/// identity; changing euid only after bridge startup is not sufficient for MFMount.
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
    (uid != 0).then_some((uid, gid))
}

/// std::fs opens descriptors with FD_CLOEXEC. The raw source must survive the
/// exec into launchctl and then into usbcore bridge, so clear only that flag.
fn make_fd_inheritable(fd: i32) -> std::io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}
'''
if old_helper in text:
    text = text.replace(old_helper, new_helper, 1)
elif new_helper not in text:
    raise SystemExit("console GUI helper not found after base preview")

# User bridge writes performance data outside root-only session storage.
old_perf = '    let performance_path = session_dir.join("performance.json");'
new_perf = '''    let performance_path = PathBuf::from("/tmp")
        .join(format!("com.edp.usbvault-{session_id}-performance.json"));'''
if old_perf in text:
    text = text.replace(old_perf, new_perf, 1)
elif new_perf not in text:
    raise SystemExit("performance path snippet not found")

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
        .arg("bridge")
        .arg(source)
        .arg(&bridge_mount)
        .args([
            "--start-sector",
            &desc.start_sector.to_string(),
            "--size-bytes",
            &desc.size_bytes.to_string(),
            "--partition-type",
            &desc.partition_type.to_string(),
            "--key-fd",
            &fds[0].to_string(),
            "--ready-fd",
            &ready_fds[1].to_string(),
            "--performance-path",
            performance_path.to_string_lossy().as_ref(),
        ])
'''
new_spawn = '''    let self_exe = std::env::current_exe()?;
    let bridge_gui_identity = console_gui_identity();

    // Open the raw source while the daemon is still root. The bridge will inherit
    // this descriptor and therefore never needs TCC/raw-device permission itself.
    use std::os::unix::io::AsRawFd;
    use std::os::unix::process::CommandExt;
    let source_file = std::fs::OpenOptions::new()
        .read(true)
        .write(!readonly)
        .open(source)
        .with_context(|| format!("root daemon 打开原始设备 {} 失败", source.display()))?;
    let source_fd = source_file.as_raw_fd();
    make_fd_inheritable(source_fd).context("设置 raw source FD 可继承失败")?;

    // /Volumes itself is root-owned. Create/chown the hidden mountpoint before
    // dropping the child to the real console identity.
    std::fs::create_dir_all(&bridge_mount)?;
    if let Some((uid, gid)) = bridge_gui_identity {
        let owner = format!("{uid}:{gid}");
        let status = Command::new("/usr/sbin/chown")
            .arg(&owner)
            .arg(&bridge_mount)
            .status()?;
        if !status.success() {
            bail!("chown {} -> {owner} 失败", bridge_mount.display());
        }
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bridge_mount, std::fs::Permissions::from_mode(0o700))?;
    }

    let mut command = if let Some((uid, gid)) = bridge_gui_identity {
        let mut command = Command::new("/bin/launchctl");
        command.arg("asuser").arg(uid.to_string()).arg(&self_exe);
        // Crucial: launchctl itself is exec'd as the real user, so the later
        // usbcore bridge process is born in the correct uid/audit context.
        command.gid(gid).uid(uid);
        command
    } else {
        Command::new(&self_exe)
    };
    info!(
        "bridge spawn: daemon_euid={} exec_identity={:?} inherited_source_fd={source_fd}",
        unsafe { libc::geteuid() },
        bridge_gui_identity
    );
    let mut child = command
        .arg("bridge")
        .arg(source)
        .arg(&bridge_mount)
        .args([
            "--start-sector",
            &desc.start_sector.to_string(),
            "--size-bytes",
            &desc.size_bytes.to_string(),
            "--partition-type",
            &desc.partition_type.to_string(),
            "--key-fd",
            &fds[0].to_string(),
            "--source-fd",
            &source_fd.to_string(),
            "--ready-fd",
            &ready_fds[1].to_string(),
            "--performance-path",
            performance_path.to_string_lossy().as_ref(),
        ])
'''
if old_spawn in text:
    text = text.replace(old_spawn, new_spawn, 1)
elif new_spawn not in text:
    raise SystemExit("bridge spawn block not found after base preview")

session.write_text(text)

# Installer-facing diagnostic text for this experiment.
installer = ROOT / "installer/build-one-click.sh"
installer_text = installer.read_text()
installer_text = installer_text.replace(
    "root daemon installed; FSKit bridge will enter gui/${CONSOLE_UID:-unknown} via launchctl asuser",
    "root daemon installed; raw disk is opened by root and inherited by a real-user FSKit bridge",
)
installer_text = installer_text.replace(
    "后台服务保持管理员权限访问原始 U 盘，仅 macFUSE/FSKit 桥接进程进入当前用户会话。",
    "后台服务以管理员权限打开原始 U 盘；macFUSE/FSKit 桥接进程从启动起即为当前登录用户。",
)
installer.write_text(installer_text)

print("Applied FSKit exec-user preview: root open raw FD -> real-user launchctl/bridge exec -> MFMount")
