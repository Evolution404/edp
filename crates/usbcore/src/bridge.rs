//! macFUSE 单文件桥：把 EDP 密文分区暴露为可随机读写的明文 `volume.raw`。
//!
//! 语义对照 `mac_edp_usb/raw_bridge.py`：
//! - 仅根目录 + 单个固定大小文件；O_TRUNC 恒拒 EPERM；越界写 ENOSPC
//! - `direct_io`/`noappledouble`/`nobrowse`/`local`/`volname` 经
//!   `MountOption::Custom` 传递（fuser 无原生对应项）
//! - file_key 经匿名管道（`--key-fd`）传入，绝不进 argv/env

use std::ffi::OsStr;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime};

use fuser::{
    FileAttr, Filesystem, KernelConfig, MountOption, ReplyAttr, ReplyDirectory, ReplyEmpty,
    ReplyEntry, ReplyOpen, ReplyStatfs, ReplyWrite, Request, TimeOrNow,
};
use tracing::{info, warn};

use edp_core::lba12::VolumeDescriptor;
use edp_core::volume::{EncryptedPartitionIO, FileRawIo};
use edp_core::SecretKey16;

/// 暴露的虚拟文件名。
pub const VIRTUAL_NAME: &str = "volume.raw";
const ROOT_INO: u64 = 1;
const FILE_INO: u64 = 2;
const TTL: Duration = Duration::from_secs(1);
const REQUEST_BYTES: u32 = 1024 * 1024;

type Job = Box<dyn FnOnce() + Send + 'static>;

struct JobPool {
    sender: std::sync::mpsc::SyncSender<Job>,
    pending: Arc<(Mutex<usize>, Condvar)>,
}

impl JobPool {
    fn new() -> Self {
        let workers = std::thread::available_parallelism()
            .map(|value| value.get().min(4))
            .unwrap_or(2);
        let (sender, receiver) = std::sync::mpsc::sync_channel::<Job>(workers * 4);
        let receiver = Arc::new(Mutex::new(receiver));
        let pending = Arc::new((Mutex::new(0usize), Condvar::new()));
        for index in 0..workers {
            let receiver = receiver.clone();
            let pending = pending.clone();
            std::thread::Builder::new()
                .name(format!("edp-io-{index}"))
                .spawn(move || loop {
                    let job = receiver.lock().unwrap().recv();
                    let Ok(job) = job else { break };
                    job();
                    let (lock, wake) = &*pending;
                    let mut count = lock.lock().unwrap();
                    *count -= 1;
                    if *count == 0 {
                        wake.notify_all();
                    }
                })
                .expect("创建 bridge I/O 工作线程失败");
        }
        info!("bridge: I/O workers={workers}");
        Self { sender, pending }
    }

    fn execute(&self, job: Job) {
        let (lock, _) = &*self.pending;
        *lock.lock().unwrap() += 1;
        if let Err(error) = self.sender.send(job) {
            (error.0)();
            let (lock, wake) = &*self.pending;
            let mut count = lock.lock().unwrap();
            *count -= 1;
            if *count == 0 {
                wake.notify_all();
            }
        }
    }

    fn drain(&self) {
        let (lock, wake) = &*self.pending;
        let mut count = lock.lock().unwrap();
        while *count != 0 {
            count = wake.wait(count).unwrap();
        }
    }
}

struct RawVolumeBridge {
    volume: Arc<EncryptedPartitionIO>,
    readonly: bool,
    jobs: JobPool,
}

fn now() -> SystemTime {
    SystemTime::now()
}

fn file_attr(volume_size: u64, readonly: bool) -> FileAttr {
    FileAttr {
        ino: FILE_INO,
        size: volume_size,
        blocks: volume_size.div_ceil(512),
        atime: now(),
        mtime: now(),
        ctime: now(),
        crtime: now(),
        kind: fuser::FileType::RegularFile,
        perm: if readonly { 0o400 } else { 0o600 },
        nlink: 1,
        uid: nix_uid(),
        gid: nix_gid(),
        rdev: 0,
        blksize: REQUEST_BYTES,
        flags: 0,
    }
}

fn root_attr() -> FileAttr {
    FileAttr {
        ino: ROOT_INO,
        size: 0,
        blocks: 0,
        atime: now(),
        mtime: now(),
        ctime: now(),
        crtime: now(),
        kind: fuser::FileType::Directory,
        perm: 0o700,
        nlink: 2,
        uid: nix_uid(),
        gid: nix_gid(),
        rdev: 0,
        blksize: REQUEST_BYTES,
        flags: 0,
    }
}

fn nix_uid() -> u32 {
    #[cfg(unix)]
    {
        unsafe { libc::getuid() }
    }
    #[cfg(not(unix))]
    {
        501
    }
}

fn nix_gid() -> u32 {
    #[cfg(unix)]
    {
        unsafe { libc::getgid() }
    }
    #[cfg(not(unix))]
    {
        20
    }
}

impl Filesystem for RawVolumeBridge {
    fn init(&mut self, _req: &Request<'_>, config: &mut KernelConfig) -> Result<(), libc::c_int> {
        // 放宽 FUSE 单次读写上限（默认偏小会把 hdiutil/exFAT 的成块写碎片化，
        // 实测限制拷贝吞吐）。set_max_write 失败（内核不认可）时静默用默认。
        let max_write = config
            .set_max_write(REQUEST_BYTES)
            .map(|_| REQUEST_BYTES)
            .unwrap_or_else(|limit| {
                let _ = config.set_max_write(limit);
                limit
            });
        let max_readahead = config
            .set_max_readahead(REQUEST_BYTES)
            .map(|_| REQUEST_BYTES)
            .unwrap_or_else(|limit| {
                if limit > 0 {
                    let _ = config.set_max_readahead(limit);
                }
                limit
            });
        info!(
            "bridge: 已挂载 readonly={} max_write={} max_readahead={}",
            self.readonly, max_write, max_readahead
        );
        Ok(())
    }

    fn destroy(&mut self) {
        self.jobs.drain();
        if let Err(e) = self.volume.sync() {
            warn!("bridge: destroy sync 失败: {e}");
        }
        info!("bridge: 已卸载");
    }

    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        if parent != ROOT_INO || name != VIRTUAL_NAME {
            reply.error(libc::ENOENT);
            return;
        }
        reply.entry(&TTL, &file_attr(self.volume.size(), self.readonly), 0);
    }

    fn getattr(&mut self, _req: &Request<'_>, ino: u64, _fh: Option<u64>, reply: ReplyAttr) {
        match ino {
            ROOT_INO => reply.attr(&TTL, &root_attr()),
            FILE_INO => reply.attr(&TTL, &file_attr(self.volume.size(), self.readonly)),
            _ => reply.error(libc::ENOENT),
        }
    }

    fn setattr(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<TimeOrNow>,
        _mtime: Option<TimeOrNow>,
        _ctime: Option<std::time::SystemTime>,
        _fh: Option<u64>,
        _crtime: Option<std::time::SystemTime>,
        _chgtime: Option<std::time::SystemTime>,
        _bkuptime: Option<std::time::SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        if ino != FILE_INO {
            reply.error(libc::ENOENT);
            return;
        }
        // 卷大小固定：truncate 到原值是 no-op，其余一律拒绝
        if let Some(new_size) = size {
            if new_size != self.volume.size() {
                reply.error(libc::EPERM);
                return;
            }
        }
        reply.attr(&TTL, &file_attr(self.volume.size(), self.readonly));
    }

    fn readdir(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        if ino != ROOT_INO {
            reply.error(libc::ENOTDIR);
            return;
        }
        let entries = [
            (ROOT_INO, fuser::FileType::Directory, "."),
            (ROOT_INO, fuser::FileType::Directory, ".."),
            (FILE_INO, fuser::FileType::RegularFile, VIRTUAL_NAME),
        ];
        for (i, (entry_ino, kind, name)) in entries.iter().enumerate().skip(offset.max(0) as usize)
        {
            if reply.add(*entry_ino, (i + 1) as i64, *kind, name) {
                break;
            }
        }
        reply.ok();
    }

    fn open(&mut self, _req: &Request<'_>, ino: u64, flags: i32, reply: ReplyOpen) {
        if ino != FILE_INO {
            reply.error(libc::ENOENT);
            return;
        }
        let write = flags & libc::O_WRONLY != 0 || flags & libc::O_RDWR != 0;
        if self.readonly && write {
            reply.error(libc::EROFS);
            return;
        }
        if flags & libc::O_TRUNC != 0 {
            reply.error(libc::EPERM);
            return;
        }
        // 使用 macFUSE 的缓存 I/O，让 hdiutil 获得顺序预读和写合并。
        reply.opened(0, 0);
    }

    fn read(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        size: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: fuser::ReplyData,
    ) {
        if ino != FILE_INO {
            reply.error(libc::ENOENT);
            return;
        }
        let offset = offset.max(0) as u64;
        let total = self.volume.size();
        if offset >= total {
            reply.data(&[]);
            return;
        }
        let want = (size as u64).min(total - offset) as usize;
        let volume = self.volume.clone();
        self.jobs.execute(Box::new(move || {
            let mut buf = vec![0u8; want];
            match volume.read(offset, &mut buf) {
                Ok(()) => reply.data(&buf),
                Err(e) => {
                    warn!("bridge: read 失败 offset={offset}: {e}");
                    reply.error(libc::EIO);
                }
            }
        }));
    }

    fn write(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        data: &[u8],
        _write_flags: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyWrite,
    ) {
        if ino != FILE_INO {
            reply.error(libc::ENOENT);
            return;
        }
        if self.readonly {
            reply.error(libc::EROFS);
            return;
        }
        let offset = offset.max(0) as u64;
        if offset + data.len() as u64 > self.volume.size() {
            reply.error(libc::ENOSPC);
            return;
        }
        let volume = self.volume.clone();
        let data = data.to_vec();
        self.jobs
            .execute(Box::new(move || match volume.write(offset, &data) {
                Ok(n) => reply.written(n as u32),
                Err(e) => {
                    warn!("bridge: write 失败 offset={offset}: {e}");
                    reply.error(libc::EIO);
                }
            }));
    }

    fn flush(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        _lock_owner: u64,
        reply: ReplyEmpty,
    ) {
        if ino == FILE_INO {
            self.jobs.drain();
            if let Err(e) = self.volume.flush() {
                warn!("bridge: flush 失败: {e}");
                reply.error(libc::EIO);
                return;
            }
        }
        reply.ok();
    }

    fn fsync(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        _datasync: bool,
        reply: ReplyEmpty,
    ) {
        if ino == FILE_INO {
            self.jobs.drain();
            if let Err(e) = self.volume.sync() {
                warn!("bridge: fsync 失败: {e}");
                reply.error(libc::EIO);
                return;
            }
        }
        reply.ok();
    }

    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        let blocks = self.volume.size().div_ceil(4096);
        reply.statfs(blocks, 0, 0, 2, 0, 4096, 255, 4096);
    }
}

/// 挂载选项（macFUSE 专属项经 CUSTOM 传递；direct_io 走 open reply 标志）。
fn mount_options() -> Vec<MountOption> {
    vec![
        MountOption::FSName("edp-usb".into()),
        MountOption::CUSTOM("volname=EDP Raw Bridge".into()),
        MountOption::CUSTOM("local".into()),
        MountOption::CUSTOM("noappledouble".into()),
        MountOption::CUSTOM("nobrowse".into()),
        MountOption::CUSTOM("async".into()),
        MountOption::CUSTOM(format!("iosize={REQUEST_BYTES}")),
        MountOption::DefaultPermissions,
    ]
}

/// 从 `--key-fd` 匿名管道读出 16 字节 file_key。
fn read_key_from_fd(fd: i32) -> anyhow::Result<SecretKey16> {
    use std::io::Read;
    use std::os::unix::io::FromRawFd;
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut buf = [0u8; 16];
    file.read_exact(&mut buf)?;
    drop(file); // 关闭读端
    Ok(SecretKey16::from(buf))
}

/// `usbcore bridge` 入口（daemon/CLI 内部 spawn，不面向最终用户文档）。
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
    let bridge = RawVolumeBridge {
        volume: volume.clone(),
        readonly,
        jobs: JobPool::new(),
    };
    info!(
        "bridge: source={} mount={} start_sector={start_sector} size={size_bytes}",
        source.display(),
        mountpoint.display()
    );
    let mut session = fuser::Session::new(bridge, mountpoint, &mount_options())?;
    if let Some(fd) = ready_fd {
        use std::io::Write;
        use std::os::unix::io::FromRawFd;
        let mut ready = unsafe { std::fs::File::from_raw_fd(fd) };
        ready.write_all(&[1])?;
    }

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
    let result = session.run();
    stop.store(true, Ordering::Relaxed);
    if let Some(reporter) = reporter {
        let _ = reporter.join();
    }
    result?;
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
