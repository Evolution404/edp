//! macFUSE 单文件桥：把 EDP 密文分区暴露为可随机读写的明文 `volume.raw`。
//!
//! macOS 15.4+ 使用 macFUSE 官方 libfuse 的 FSKit backend。这里不再使用
//! `fuser::Session`：fuser 的 Rust 会话层仍依赖传统 FUSE 设备 fd，而
//! macFUSE FSKit 通过 MFMount 的消息通道传输。C shim 仅负责 libfuse 回调，
//! 实际加解密 I/O 仍由 Rust `EncryptedPartitionIO` 完成。

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
    let io = Arc::new(FileRawIo::open(source, readonly)?);
    let volume = Arc::new(EncryptedPartitionIO::open(io, desc, readonly)?);
    std::fs::create_dir_all(mountpoint)?;

    info!(
        "bridge(libfuse/FSKit): source={} mount={} start_sector={start_sector} size={size_bytes} priority_raised={priority_raised}",
        source.display(),
        mountpoint.display()
    );

    let ready_notifier = ready_fd.map(|fd| {
        use std::io::Write;
        use std::os::unix::io::FromRawFd;
        let virtual_file = mountpoint.join(VIRTUAL_NAME);
        std::thread::spawn(move || {
            let mut ready = unsafe { std::fs::File::from_raw_fd(fd) };
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
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
