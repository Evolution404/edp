//! 挂载编排与会话管理（对照 `edp_usb.py` 的已验证顺序）。
//!
//! 挂载链：`diskutil unmountDisk` → spawn `usbcore bridge`（file_key 走匿名
//! 管道）→ 轮询 `bridge/volume.raw` 出现 → `hdiutil attach -owners off` →
//! 无挂载点则 `diskutil mount` → 写 session.json（不含密码与密钥）。
//! 卸载：`hdiutil detach [-force]` → umount bridge → SIGTERM/SIGKILL bridge
//! （先验证 pid 归属防误杀）。

use std::io::Write;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tracing::{info, warn};

use edp_core::lba12::VolumeDescriptor;

const SELF_EXE_HINT: &str = "usbcore";

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

/// bridge 进程是否归属本工具（防误杀；bridge_mount 参数保留给更严格的校验）。
fn bridge_process_matches(pid: u32, _bridge_mount: &Path) -> bool {
    let out = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output();
    let Ok(out) = out else { return false };
    let cmd = String::from_utf8_lossy(&out.stdout);
    out.status.success() && cmd.contains(SELF_EXE_HINT) && cmd.contains("bridge")
}

fn terminate_bridge(pid: u32, bridge_mount: &Path) {
    edp_macos::umount_path(bridge_mount);
    if !bridge_process_matches(pid, bridge_mount) {
        return;
    }
    let _ = kill(pid, libc::SIGTERM);
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if !process_alive(pid) {
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = kill(pid, libc::SIGKILL);
}

fn process_alive(pid: u32) -> bool {
    let out = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "pid="])
        .output();
    out.map(|o| o.status.success()).unwrap_or(false)
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

    // 匿名管道传 file_key（绝不进 argv/env）
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error()).context("pipe 创建失败");
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
    unsafe { libc::close(fds[0]) };

    // 轮询 volume.raw 出现（≤15s）
    let virtual_file = bridge_mount.join("volume.raw");
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if virtual_file.exists() {
            break;
        }
        if let Some(status) = child.try_wait()? {
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            bail!(
                "bridge 提前退出 status={status}；日志:\n{log}",
                status = status
                    .signal()
                    .map(|s| format!("signal {s}"))
                    .unwrap_or_else(|| status.to_string())
            );
        }
        if Instant::now() > deadline {
            terminate_bridge(child.id(), &bridge_mount);
            bail!("等待 bridge 挂起超时（15s）");
        }
        std::thread::sleep(Duration::from_millis(200));
    }

    // hdiutil attach
    let attach = edp_macos::hdiutil_attach_raw(&virtual_file, readonly, mountpoint);
    match attach {
        Ok((devices, mountpoints)) => {
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
                "devices": devices,
                "mountpoints": mountpoints,
            });
            let state_path = session_dir.join("session.json");
            std::fs::write(&state_path, serde_json::to_vec_pretty(&state)?)?;
            info!("已挂载: session={session_id} mountpoints={:?}", mountpoints);
            Ok(state)
        }
        Err(e) => {
            terminate_bridge(child.id(), &bridge_mount);
            Err(e).context("hdiutil attach 失败")
        }
    }
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
    prepare_session_root(session_root)?;
    let session_dir = session_dir_valid(session_root, session_id)?;
    let state_path = session_dir.join("session.json");
    let state: Value = serde_json::from_str(&std::fs::read_to_string(&state_path)?)
        .with_context(|| format!("读取会话状态失败: {}", state_path.display()))?;

    // 1. detach 虚拟整盘
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

    // 2. 终止 bridge
    if let (Some(pid), Some(mp)) = (state["bridge_pid"].as_u64(), state["bridge_mount"].as_str()) {
        terminate_bridge(pid as u32, Path::new(mp));
    }

    // 3. 更新状态
    let mut state = state;
    state["active"] = json!(false);
    state["unmounted_at"] = json!(chrono::Local::now()
        .format("%Y-%m-%dT%H:%M:%S%z")
        .to_string());
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
            sessions.push(v);
        }
    }
    Ok(json!({ "sessions": sessions }))
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
