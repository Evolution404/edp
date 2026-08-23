//! macFUSE 单文件桥：把 EDP 密文分区暴露为可随机读写的明文 `volume.raw`。
//!
//! 语义对照 `mac_edp_usb/raw_bridge.py`：
//! - 仅根目录 + 单个固定大小文件；O_TRUNC 恒拒 EPERM；越界写 ENOSPC
//! - `direct_io`/`noappledouble`/`nobrowse`/`local`/`volname` 经
//!   `MountOption::Custom` 传递（fuser 无原生对应项）
//! - file_key 经匿名管道（`--key-fd`）传入，绝不进 argv/env

use std::ffi::OsStr;
use std::path::Path;
use std::sync::Arc;
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
/// FUSE FOPEN_DIRECT_IO（libfuse 语义，等价 fusepy 的 direct_io=True）。
const FOPEN_DIRECT_IO: u32 = 0x2;

struct RawVolumeBridge {
    volume: EncryptedPartitionIO,
    readonly: bool,
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
        blksize: 128 * 1024,
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
        blksize: 128 * 1024,
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
        let _ = config.set_max_write(128 * 1024);
        info!("bridge: 已挂载（readonly={}）", self.readonly);
        Ok(())
    }

    fn destroy(&mut self) {
        if let Err(e) = self.volume.flush() {
            warn!("bridge: destroy flush 失败: {e}");
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
        reply.opened(0, FOPEN_DIRECT_IO);
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
        let mut buf = vec![0u8; want];
        match self.volume.read(offset, &mut buf) {
            Ok(()) => reply.data(&buf),
            Err(e) => {
                warn!("bridge: read 失败 offset={offset}: {e}");
                reply.error(libc::EIO);
            }
        }
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
        match self.volume.write(offset, data) {
            Ok(n) => reply.written(n as u32),
            Err(e) => {
                warn!("bridge: write 失败 offset={offset}: {e}");
                reply.error(libc::EIO);
            }
        }
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
            if let Err(e) = self.volume.flush() {
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
pub fn run(
    source: &Path,
    mountpoint: &Path,
    start_sector: u64,
    size_bytes: u64,
    partition_type: u32,
    key_fd: i32,
    readonly: bool,
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
    let volume = EncryptedPartitionIO::open(io, desc, readonly)?;
    std::fs::create_dir_all(mountpoint)?;
    let bridge = RawVolumeBridge { volume, readonly };
    info!(
        "bridge: source={} mount={} start_sector={start_sector} size={size_bytes}",
        source.display(),
        mountpoint.display()
    );
    fuser::mount2(bridge, mountpoint, &mount_options())?;
    Ok(())
}
