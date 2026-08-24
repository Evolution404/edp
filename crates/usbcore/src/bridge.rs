//! macFUSE 单文件桥：把 EDP 密文分区暴露为可随机读写的明文 `volume.raw`。
//!
//! macOS 15.4+ 使用 macFUSE 官方 libfuse 的 FSKit backend。这里不再使用
//! `fuser::Session`：fuser 的 Rust 会话层仍依赖传统 FUSE 设备 fd，而
//! macFUSE FSKit 通过 MFMount 的消息通道传输。C shim 仅负责 libfuse 回调，
//! 实际加解密 I/O 仍由 Rust `EncryptedPartitionIO` 完成。
//!
//! root LaunchDaemon 启动 bridge 时，bridge 会先以 root 身份打开 `/dev/rdiskN`，
//! 然后在进入 libfuse/FSKit 前真正降权到当前控制台用户。已经打开的原始磁盘
//! FD 在降权后继续有效，因此可以同时满足原始磁盘访问和 FSKit 用户授权模型。

use std::ffi::{c_void, CString};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context};
use tracing::{info, warn};

use edp_core::lba12::VolumeDescriptor;
use edp_core::volume::{EncryptedPartitionIO, FileRawIo};
use edp_core::SecretKey16;

pub const VIRTUAL_NAME: &str = "volume.raw";

struct BridgeContext {
    volume: Arc<EncryptedPartitionIO>,
    readonly: bool,
}

extern "C" {
    fn edp_fuse_run(ctx: *mut c_void, mountpoint: *const libc::c_char, size: u64, readonly: i32)
        -> i32;
}

#[no_mangle]
pub unsafe extern "C" fn edp_bridge_read(
    ctx: *mut c_void,
    offset: u64,
    buf: *mut c_void,
    size: usize,
) -> i64 {
    if ctx.is_null() || (buf.is_null() && size != 0) {
        return -(libc::EINVAL as i64);
    }
    let bridge = &*(ctx as *mut BridgeContext);
    let total = bridge.volume.size();
    if offset >= total {
        return 0;
    }
    let want = size.min((total - offset) as usize);
    let target = std::slice::from_raw_parts_mut(buf as *mut u8, want);
    match bridge.volume.read(offset, target) {
        Ok(()) => want as i64,
        Err(error) => {
            warn!("bridge: read 失败 offset={offset}: {error}");
            -(libc::EIO as i64)
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn edp_bridge_write(
    ctx: *mut c_void,
    offset: u64,
    buf: *const c_void,
    size: usize,
) -> i64 {
    if ctx.is_null() || (buf.is_null() && size != 0) {
        return -(libc::EINVAL as i64);
    }
    let bridge = &*(ctx as *mut BridgeContext);
    if bridge.readonly {
        return -(libc::EROFS as i64);
    }
    let total = bridge.volume.size();
    if offset > total || size as u64 > total.saturating_sub(offset) {
        return -(libc::ENOSPC as i64);
    }
    let source = std::slice::from_raw_parts(buf as *const u8, size);
    match bridge.volume.write(offset, source) {
        Ok(written) => written as i64,
        Err(error) => {
            warn!("bridge: write 失败 offset={offset}: {error}");
            -(libc::EIO as i64)
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn edp_bridge_sync(ctx: *mut c_void) -> i32 {
    if ctx.is_null() {
        return -libc::EINVAL;
    }
    let bridge = &*(ctx as *mut BridgeContext);
    match bridge.volume.sync() {
        Ok(()) => 0,
        Err(error) => {
            warn!("bridge: sync 失败: {error}");
            -libc::EIO
        }
    }
}

fn read_key_from_fd(fd: i32) -> anyhow::Result<SecretKey16> {
    use std::io::Read;
    use std::os::unix::io::FromRawFd;
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut buf = [0u8; 16];
    file.read_exact(&mut buf)?;
    drop(file);
    Ok(SecretKey16::from(buf))
}

/// Preview-only bridge identity, supplied by the privileged session launcher.
/// Both values must be present together; otherwise the bridge keeps its current uid/gid.
fn requested_run_identity() -> anyhow::Result<Option<(libc::uid_t, libc::gid_t)>> {
    let uid = std::env::var("EDP_BRIDGE_RUN_UID").ok();
    let gid = std::env::var("EDP_BRIDGE_RUN_GID").ok();
    match (uid, gid) {
        (None, None) => Ok(None),
        (Some(uid), Some(gid)) => {
            let uid = uid.parse::<libc::uid_t>().context("EDP_BRIDGE_RUN_UID 非法")?;
            let gid = gid.parse::<libc::gid_t>().context("EDP_BRIDGE_RUN_GID 非法")?;
            if uid == 0 {
                bail!("EDP_BRIDGE_RUN_UID 不能为 0");
            }
            Ok(Some((uid, gid)))
        }
        _ => bail!("EDP_BRIDGE_RUN_UID/EDP_BRIDGE_RUN_GID 必须同时设置"),
    }
}

fn prepare_user_mountpoint(
    mountpoint: &Path,
    identity: Option<(libc::uid_t, libc::gid_t)>,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(mountpoint)?;
    if let Some((uid, gid)) = identity {
        let mountpoint_c = CString::new(mountpoint.as_os_str().as_bytes())
            .context("bridge mountpoint 包含 NUL")?;
        if unsafe { libc::chown(mountpoint_c.as_ptr(), uid, gid) } != 0 {
            return Err(std::io::Error::last_os_error()).with_context(|| {
                format!("chown bridge mountpoint {} -> {uid}:{gid}", mountpoint.display())
            });
        }
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(mountpoint, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Keep the raw disk File opened by root, but make MFMount/FSKit itself run with the
/// real console user's credentials. `launchctl asuser` has already selected the GUI
/// bootstrap before this function is called; this function changes only credentials.
fn drop_to_user(uid: libc::uid_t, gid: libc::gid_t) -> anyhow::Result<()> {
    let current = unsafe { libc::geteuid() };
    if current == uid {
        return Ok(());
    }
    if current != 0 {
        bail!("bridge 无法从 euid={current} 降权到 uid={uid}");
    }

    // Do not retain root supplementary groups in the user-space file-system server.
    if unsafe { libc::setgroups(0, std::ptr::null()) } != 0 {
        return Err(std::io::Error::last_os_error()).context("bridge setgroups 失败");
    }
    if unsafe { libc::setgid(gid) } != 0 {
        return Err(std::io::Error::last_os_error()).context("bridge setgid 失败");
    }
    if unsafe { libc::setuid(uid) } != 0 {
        return Err(std::io::Error::last_os_error()).context("bridge setuid 失败");
    }
    if unsafe { libc::geteuid() } != uid || unsafe { libc::getegid() } != gid {
        bail!("bridge 降权后 uid/gid 校验失败");
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    source: &Path,
    mountpoint: &Path,
    start_sector: u64,
    size_bytes: u64,
    partition_type: u32,
    key_fd: i32,
    readonly: bool,
    ready_fd: Option<i32>,
    performance_path: Option<&Path>,
) -> anyhow::Result<()> {
    let priority_raised = edp_core::qos::prioritize_current_process_for_io();
    edp_core::qos::set_current_thread_user_initiated();
    let key = read_key_from_fd(key_fd)?;
    let desc = VolumeDescriptor {
        partition_type,
        start_sector,
        size_bytes,
        algo: 2,
        file_key: Some(key),
        password_crc: 0,
        key_crc: 0,
    };

    // IMPORTANT: open the raw device while still privileged. The File stays open
    // across setuid/setgid and all later encrypted random I/O uses this descriptor.
    let io = Arc::new(FileRawIo::open(source, readonly)?);
    let volume = Arc::new(EncryptedPartitionIO::open(io, desc, readonly)?);
    let run_identity = requested_run_identity()?;
    prepare_user_mountpoint(mountpoint, run_identity)?;

    let privileged_euid = unsafe { libc::geteuid() };
    if let Some((uid, gid)) = run_identity {
        drop_to_user(uid, gid)?;
    }
    let fuse_euid = unsafe { libc::geteuid() };
    let fuse_egid = unsafe { libc::getegid() };

    info!(
        "bridge(libfuse/FSKit): source={} mount={} start_sector={start_sector} size={size_bytes} priority_raised={priority_raised} open_euid={privileged_euid} fuse_euid={fuse_euid} fuse_egid={fuse_egid}",
        source.display(),
        mountpoint.display()
    );

    let ready_notifier = ready_fd.map(|fd| {
        use std::io::Write;
        use std::os::unix::io::FromRawFd;
        let virtual_file = mountpoint.join(VIRTUAL_NAME);
        std::thread::spawn(move || {
            let mut ready = unsafe { std::fs::File::from_raw_fd(fd) };
            let deadline = std::time::Instant::now() + Duration::from_secs(8);
            while std::time::Instant::now() < deadline {
                if std::fs::metadata(&virtual_file).is_ok() {
                    let _ = ready.write_all(&[1]);
                    return;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            warn!("bridge: volume.raw 就绪验证超时");
        })
    });

    let stop = Arc::new(AtomicBool::new(false));
    let reporter = performance_path.map(|path| {
        let path = path.to_path_buf();
        let volume = volume.clone();
        let stop = stop.clone();
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                write_performance(&path, &volume.performance_snapshot());
                std::thread::sleep(Duration::from_secs(1));
            }
            write_performance(&path, &volume.performance_snapshot());
        })
    });

    let mut context = Box::new(BridgeContext {
        volume: volume.clone(),
        readonly,
    });
    let mountpoint_c = CString::new(mountpoint.as_os_str().as_bytes())
        .context("bridge mountpoint 包含 NUL")?;
    let rc = unsafe {
        edp_fuse_run(
            (&mut *context as *mut BridgeContext).cast::<c_void>(),
            mountpoint_c.as_ptr(),
            volume.size(),
            i32::from(readonly),
        )
    };

    stop.store(true, Ordering::Relaxed);
    if let Some(reporter) = reporter {
        let _ = reporter.join();
    }
    if let Some(notifier) = ready_notifier {
        let _ = notifier.join();
    }
    let _ = volume.sync();
    drop(context);

    if rc != 0 {
        bail!("macFUSE libfuse/FSKit bridge 退出 rc={rc}");
    }
    Ok(())
}

fn write_performance(path: &Path, snapshot: &edp_core::volume::IoPerformanceSnapshot) {
    let temporary = path.with_extension("tmp");
    let result = serde_json::to_vec(snapshot)
        .map_err(std::io::Error::other)
        .and_then(|bytes| std::fs::write(&temporary, bytes))
        .and_then(|_| std::fs::rename(&temporary, path));
    if let Err(error) = result {
        warn!("bridge: 写入性能快照失败: {error}");
    }
}
