//! 挂载编排与会话管理（对照 `edp_usb.py` 的已验证顺序）。
//!
//! 挂载链：`diskutil unmountDisk` → spawn `usbcore bridge`（file_key 走匿名
//! 管道）→ bridge ready 管道通知 → `hdiutil attach -owners off` →
//! 无挂载点则 `diskutil mount` → 写 session.json（不含密码与密钥）。
//! 卸载：`hdiutil detach [-force]` → umount bridge → SIGTERM/SIGKILL bridge
//! （只等待 daemon 自己 spawn 的子进程，防止 PID 复用误杀）。

use std::io::Write;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tracing::{info, warn};

use edp_core::lba12::VolumeDescriptor;

fn session_dir_valid(root: &Path, session_id: &str) -> Result<PathBuf> {
    // 会话 id 只允许 [A-Za-z0-9-_]，防路径逃逸
    if session_id.is_empty()
        || !session_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        bail!("非法 session id: {session_id}");
    }
    let root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    // 拒绝符号链接形式的根
    let meta = std::fs::symlink_metadata(&root)?;
    if meta.file_type().is_symlink() {
        bail!("会话根目录不能是符号链接");
    }
    Ok(root.join(session_id))
}

fn prepare_session_root(root: &Path) -> Result<()> {
    std::fs::create_dir_all(root).with_context(|| {
        format!(
            "创建会话根目录 {} 失败（若为旧 root 目录残留：sudo rm -rf {}）",
            root.display(),
            root.display()
        )
    })?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700)).with_context(|| {
        format!(
            "设置会话根目录 {} 权限失败（目录可能被 root 占用：sudo rm -rf {}）",
            root.display(),
            root.display()
        )
    })?;
    Ok(())
}

fn terminate_bridge(pid: u32, bridge_mount: &Path) {
    edp_macos::umount_path(bridge_mount);
    // waitpid 只能回收当前 daemon 创建的 bridge。daemon 重启后的孤儿
    // bridge 会因 FUSE unmount 自行退出；不对非子进程发信号，避免 PID 复用。
    if wait_child(pid, libc::WNOHANG) != Some(false) {
        return;
    }
    let _ = kill(pid, libc::SIGTERM);
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if matches!(wait_child(pid, libc::WNOHANG), Some(true) | None) {
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = kill(pid, libc::SIGKILL);
    let _ = wait_child(pid, 0);
}

fn process_alive(pid: u32) -> bool {
    let result = unsafe { libc::kill(pid as libc::pid_t, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Some(false)=仍运行，Some(true)=已回收，None=不是当前进程的子进程。
fn wait_child(pid: u32, options: i32) -> Option<bool> {
    let mut status = 0i32;
    let result = unsafe { libc::waitpid(pid as libc::pid_t, &mut status, options) };
    if result == pid as libc::pid_t {
        Some(true)
    } else if result == 0 {
        Some(false)
    } else {
        None
    }
}

fn kill(pid: u32, sig: i32) -> std::io::Result<()> {
    let r = unsafe { libc::kill(pid as libc::pid_t, sig) };
    if r != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// 完整挂载编排；成功返回会话状态 JSON。
#[allow(clippy::too_many_arguments)]
pub fn mount_and_attach(
    source: &Path,
    desc: &VolumeDescriptor,
    device_id: &str,
    readonly: bool,
    mountpoint: Option<&Path>,
    session_id: Option<&str>,
    session_root: &Path,
) -> Result<Value> {
    let mount_started = Instant::now();
    prepare_session_root(session_root)?;
    let session_id = session_id.map(|s| s.to_string()).unwrap_or_else(|| {
        let src_name = source.file_name().and_then(|n| n.to_str()).unwrap_or("img");
        format!(
            "edp-{}-{}",
            src_name.replace(['/', '.'], "-"),
            &uuid::Uuid::new_v4().simple().to_string()[..8]
        )
    });
    let session_dir = session_dir_valid(session_root, &session_id)?;
    std::fs::create_dir_all(&session_dir)
        .with_context(|| format!("创建会话目录 {}", session_dir.display()))?;
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&session_dir, std::fs::Permissions::from_mode(0o700))?;
    }

    let bridge_mount = session_dir.join("bridge");
    let log_path = session_dir.join("bridge.log");
    let performance_path = session_dir.join("performance.json");

    // 匿名管道传 file_key（绝不进 argv/env）
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error()).context("pipe 创建失败");
    }
    let mut ready_fds = [0i32; 2];
    if unsafe { libc::pipe(ready_fds.as_mut_ptr()) } != 0 {
        unsafe {
            libc::close(fds[0]);
            libc::close(fds[1]);
        }
        return Err(std::io::Error::last_os_error()).context("ready pipe 创建失败");
    }
    let key = desc
        .file_key
        .as_ref()
        .context("descriptor 缺少 file_key")?
        .as_bytes()
        .to_vec();
    let self_exe = std::env::current_exe()?;
    let mut child = Command::new(&self_exe)
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
        .arg_if(readonly, "--readonly")
        .stdout(Stdio::null())
        .stderr({
            let f = std::fs::File::create(&log_path)?;
            Stdio::from(f)
        })
        .spawn()
        .context("spawn bridge 失败")?;
    // 父进程：写 key 后关闭两端
    {
        let mut w = unsafe { std::fs::File::from_raw_fd(fds[1]) };
        w.write_all(&key)?;
        w.flush()?;
    }
    unsafe {
        libc::close(fds[0]);
        libc::close(ready_fds[1]);
    }

    // bridge 在 FUSE Session 创建成功后主动通知，避免 200ms 轮询延迟。
    wait_bridge_ready(ready_fds[0], &mut child, &log_path)?;
    let bridge_ready_ms = mount_started.elapsed().as_millis() as u64;
    let virtual_file = bridge_mount.join("volume.raw");
    if !virtual_file.exists() {
        terminate_bridge(child.id(), &bridge_mount);
        bail!("bridge 已就绪但虚拟卷文件不存在");
    }

    let attach_started = Instant::now();
    let attach = edp_macos::hdiutil_attach_raw(&virtual_file, readonly, mountpoint);
    let attach_ms = attach_started.elapsed().as_millis() as u64;
    match attach {
        Ok((devices, mountpoints)) => {
            let filesystem_started = Instant::now();
            let mut mountpoints = mountpoints;
            if mountpoints.is_empty() {
                // 无自动挂载点：diskutil mount 最后一个 dev-entry
                if let Some(dev) = devices.last() {
                    match edp_macos::mount_partition(dev) {
                        Ok(mp) => mountpoints.push(mp),
                        Err(e) => warn!("diskutil mount {dev} 失败: {e}"),
                    }
                }
            }
            let filesystem_ms = filesystem_started.elapsed().as_millis() as u64;
            let total_ms = mount_started.elapsed().as_millis() as u64;
            let state = json!({
                "session_id": session_id,
                "active": true,
                "source": source.display().to_string(),
                "device_id": device_id,
                "readonly": readonly,
                "partition": desc.public_dict(),
                "bridge_pid": child.id(),
                "bridge_mount": bridge_mount.display().to_string(),
                "bridge_log": log_path.display().to_string(),
                "performance_path": performance_path.display().to_string(),
                "devices": devices,
                "mountpoints": mountpoints,
                "timings_ms": {
                    "bridge_ready": bridge_ready_ms,
                    "hdiutil_attach": attach_ms,
                    "filesystem_mount": filesystem_ms,
                    "total": total_ms,
                },
            });
            let state_path = session_dir.join("session.json");
            std::fs::write(&state_path, serde_json::to_vec_pretty(&state)?)?;
            info!(
                "已挂载: session={session_id} mountpoints={:?} total_ms={total_ms}",
                mountpoints
            );
            Ok(state)
        }
        Err(e) => {
            terminate_bridge(child.id(), &bridge_mount);
            Err(e).context("hdiutil attach 失败")
        }
    }
}

fn wait_bridge_ready(fd: i32, child: &mut std::process::Child, log_path: &Path) -> Result<()> {
    let mut pollfd = libc::pollfd {
        fd,
        events: libc::POLLIN | libc::POLLHUP,
        revents: 0,
    };
    let result = unsafe { libc::poll(&mut pollfd, 1, 15_000) };
    let mut ready = unsafe { std::fs::File::from_raw_fd(fd) };
    if result > 0 && pollfd.revents & libc::POLLIN != 0 {
        use std::io::Read;
        let mut byte = [0u8; 1];
        if ready.read_exact(&mut byte).is_ok() && byte[0] == 1 {
            return Ok(());
        }
    }
    let status = child.try_wait()?;
    let log = std::fs::read_to_string(log_path).unwrap_or_default();
    if let Some(status) = status {
        bail!(
            "bridge 提前退出 status={status}；日志:\n{log}",
            status = status
                .signal()
                .map(|signal| format!("signal {signal}"))
                .unwrap_or_else(|| status.to_string())
        );
    }
    bail!("等待 bridge 就绪超时（15s）；日志:\n{log}")
}

/// 卸载会话。
pub fn unmount(session_id: &str, force: bool, session_root: &Path) -> Result<()> {
    unmount_impl(session_id, force, session_root, true)
}

/// 卸载全部残留活动会话（daemon 启动时回收上次非正常退出的孤儿挂载）。
pub fn cleanup_all_force(session_root: &Path) {
    if let Ok(entries) = std::fs::read_dir(session_root) {
        for e in entries.flatten() {
            let sp = e.path().join("session.json");
            let Ok(text) = std::fs::read_to_string(&sp) else {
                continue;
            };
            let Ok(v) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            if v["active"].as_bool() != Some(true) {
                continue;
            }
            if let Some(sid) = v["session_id"].as_str() {
                let _ = unmount_impl(sid, true, session_root, false);
            }
        }
    }
}

fn unmount_impl(session_id: &str, force: bool, session_root: &Path, emit: bool) -> Result<()> {
    let unmount_started = Instant::now();
    prepare_session_root(session_root)?;
    let session_dir = session_dir_valid(session_root, session_id)?;
    let state_path = session_dir.join("session.json");
    let state: Value = serde_json::from_str(&std::fs::read_to_string(&state_path)?)
        .with_context(|| format!("读取会话状态失败: {}", state_path.display()))?;

    // 1. detach 虚拟整盘
    let detach_started = Instant::now();
    if let Some(devices) = state["devices"].as_array() {
        for dev in devices {
            let Some(s) = dev.as_str() else { continue };
            let Some(whole) = whole_disk_from_dev(s) else {
                continue;
            };
            let present = Command::new("diskutil")
                .args(["info", &whole])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
            if present {
                if let Err(e) = edp_macos::hdiutil_detach(&whole, false) {
                    if force {
                        edp_macos::hdiutil_detach(&whole, true)
                            .with_context(|| format!("强制 detach {whole} 失败"))?;
                    } else {
                        bail!("{e}");
                    }
                }
            }
        }
    }
    let detach_ms = detach_started.elapsed().as_millis() as u64;

    // 2. 终止 bridge
    let bridge_started = Instant::now();
    if let (Some(pid), Some(mp)) = (state["bridge_pid"].as_u64(), state["bridge_mount"].as_str()) {
        terminate_bridge(pid as u32, Path::new(mp));
    }
    let bridge_shutdown_ms = bridge_started.elapsed().as_millis() as u64;

    // 3. 更新状态
    let mut state = state;
    state["active"] = json!(false);
    state["unmounted_at"] = json!(chrono::Local::now()
        .format("%Y-%m-%dT%H:%M:%S%z")
        .to_string());
    state["unmount_timings_ms"] = json!({
        "hdiutil_detach": detach_ms,
        "bridge_shutdown": bridge_shutdown_ms,
        "total": unmount_started.elapsed().as_millis() as u64,
    });
    std::fs::write(&state_path, serde_json::to_vec_pretty(&state)?)?;
    if emit {
        println!("{}", serde_json::to_string_pretty(&state)?);
    }
    Ok(())
}

/// 列出活动会话。
pub fn list_active(session_root: &Path) -> Result<Value> {
    let mut sessions = Vec::new();
    if let Ok(entries) = std::fs::read_dir(session_root) {
        for e in entries.flatten() {
            let sp = e.path().join("session.json");
            let Ok(text) = std::fs::read_to_string(&sp) else {
                continue;
            };
            let Ok(mut v) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            if v["active"].as_bool() != Some(true) {
                continue;
            }
            let alive = v["bridge_pid"]
                .as_u64()
                .map(|p| process_alive(p as u32))
                .unwrap_or(false);
            v["bridge_alive"] = json!(alive);
            if let Some(path) = v["performance_path"].as_str() {
                if let Ok(bytes) = std::fs::read(path) {
                    if let Ok(performance) = serde_json::from_slice::<Value>(&bytes) {
                        v["io_performance"] = performance;
                    }
                }
            }
            sessions.push(v);
        }
    }
    Ok(json!({ "sessions": sessions }))
}

/// 返回最近会话的挂载/卸载计时和 bridge I/O 统计。
pub fn performance_snapshot(session_root: &Path) -> Value {
    let mut sessions = Vec::new();
    if let Ok(entries) = std::fs::read_dir(session_root) {
        for entry in entries.flatten() {
            let state_path = entry.path().join("session.json");
            let Ok(bytes) = std::fs::read(&state_path) else {
                continue;
            };
            let Ok(state) = serde_json::from_slice::<Value>(&bytes) else {
                continue;
            };
            let performance = state["performance_path"]
                .as_str()
                .and_then(|path| std::fs::read(path).ok())
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
            sessions.push(json!({
                "session_id": state["session_id"],
                "device_id": state["device_id"],
                "active": state["active"],
                "mount_timings_ms": state["timings_ms"],
                "unmount_timings_ms": state["unmount_timings_ms"],
                "io": performance,
            }));
        }
    }
    sessions.sort_by(|left, right| {
        left["session_id"]
            .as_str()
            .unwrap_or_default()
            .cmp(right["session_id"].as_str().unwrap_or_default())
    });
    if sessions.len() > 32 {
        sessions.drain(..sessions.len() - 32);
    }
    json!({ "sessions": sessions })
}

/// 清空 bridge 统计文件；不修改会话或挂载状态。
pub fn reset_performance(session_root: &Path) -> Result<()> {
    if let Ok(entries) = std::fs::read_dir(session_root) {
        for entry in entries.flatten() {
            let path = entry.path().join("performance.json");
            if path.exists() {
                std::fs::remove_file(path)?;
            }
        }
    }
    Ok(())
}

use std::os::unix::io::FromRawFd;

/// `/dev/disk4s1` / `/dev/rdisk4` → `/dev/disk4`（整盘）。
fn whole_disk_from_dev(s: &str) -> Option<String> {
    let s = s.strip_prefix("/dev/")?;
    let s = s.strip_prefix('r').unwrap_or(s);
    let digits = s.strip_prefix("disk")?;
    let n: String = digits.chars().take_while(|c| c.is_ascii_digit()).collect();
    if n.is_empty() {
        None
    } else {
        Some(format!("/dev/disk{n}"))
    }
}

trait CommandExt {
    fn arg_if(&mut self, cond: bool, arg: &str) -> &mut Self;
}

impl CommandExt for Command {
    fn arg_if(&mut self, cond: bool, arg: &str) -> &mut Self {
        if cond {
            self.arg(arg);
        }
        self
    }
}
