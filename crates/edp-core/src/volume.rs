//! 透明加解密随机访问 IO：把 EDP SM4-ECB 分区映射为任意偏移读写的明文卷。
//!
//! 语义与 `edp_volume.py::EncryptedPartitionIO` 逐行对应：
//! - 读：扩展到 16B 边界解密后切片
//! - 写：读-改-写（RMW）非对齐部分，重加密整个边界范围
//! - 读请求可并行，写请求仅对冲突范围加锁
//! - flush 仅表示提交请求，fsync/安全卸载才下传持久化屏障

use std::fs::OpenOptions;
use std::io::SeekFrom;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::lba12::VolumeDescriptor;
use crate::sm4_ecb::Sm4Ecb;
use crate::{CoreError, BLOCK_SIZE};

/// 底层随机访问抽象（真实设备 / 镜像文件 / 测试内存）。
pub trait RawIo: Send + Sync {
    fn pread_exact(&self, off: u64, buf: &mut [u8]) -> std::io::Result<()>;
    fn pwrite_all(&self, off: u64, data: &[u8]) -> std::io::Result<()>;
    fn size(&self) -> u64;
    fn fsync(&self) -> std::io::Result<()>;
    /// 是否为块设备（设备不做镜像式边界检查，容量由 diskutil 层校验）。
    fn is_device(&self) -> bool {
        false
    }
}

/// 镜像文件 / 整盘 `/dev/rdiskN` 的实现（read+write 双向打开）。
pub struct FileRawIo {
    file: std::fs::File,
    path: std::path::PathBuf,
    size: u64,
    is_device: bool,
}

impl FileRawIo {
    /// 以指定模式打开（readonly=true 时 O_RDONLY）。
    pub fn open(path: &Path, readonly: bool) -> std::io::Result<Self> {
        let file = OpenOptions::new().read(true).write(!readonly).open(path)?;
        let is_device = path.starts_with("/dev/");
        let size = if is_device {
            // 块设备的 st_size 不可靠，seek End 取容量（失败为 0——
            // 设备不做镜像式边界检查，容量由调用方经 diskutil 校验）。
            use std::io::Seek;
            let mut f = file.try_clone()?;
            f.seek(SeekFrom::End(0)).unwrap_or(0)
        } else {
            file.metadata()?.len()
        };
        Ok(Self {
            file,
            path: path.to_path_buf(),
            size,
            is_device,
        })
    }

    /// 底层路径（诊断用）。
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl RawIo for FileRawIo {
    fn is_device(&self) -> bool {
        self.is_device
    }

    fn pread_exact(&self, off: u64, buf: &mut [u8]) -> std::io::Result<()> {
        use std::os::unix::fs::FileExt;
        self.file.read_exact_at(buf, off)
    }

    fn pwrite_all(&self, off: u64, data: &[u8]) -> std::io::Result<()> {
        use std::os::unix::fs::FileExt;
        self.file.write_all_at(data, off)
    }

    fn size(&self) -> u64 {
        self.size
    }

    fn fsync(&self) -> std::io::Result<()> {
        self.file.sync_all()
    }
}

/// 透明卷 I/O 的无锁统计快照。
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct IoPerformanceSnapshot {
    pub read_ops: u64,
    pub read_bytes: u64,
    pub write_ops: u64,
    pub write_bytes: u64,
    pub device_read_ns: u64,
    pub device_write_ns: u64,
    pub crypto_read_ns: u64,
    pub crypto_write_ns: u64,
    pub sync_ops: u64,
    pub sync_ns: u64,
    pub inflight: u64,
    pub max_inflight: u64,
}

#[derive(Default)]
struct IoPerformance {
    read_ops: AtomicU64,
    read_bytes: AtomicU64,
    write_ops: AtomicU64,
    write_bytes: AtomicU64,
    device_read_ns: AtomicU64,
    device_write_ns: AtomicU64,
    crypto_read_ns: AtomicU64,
    crypto_write_ns: AtomicU64,
    sync_ops: AtomicU64,
    sync_ns: AtomicU64,
    inflight: AtomicU64,
    max_inflight: AtomicU64,
}

impl IoPerformance {
    fn enter(&self) -> InflightGuard<'_> {
        let current = self.inflight.fetch_add(1, Ordering::Relaxed) + 1;
        self.max_inflight.fetch_max(current, Ordering::Relaxed);
        InflightGuard(self)
    }

    fn snapshot(&self) -> IoPerformanceSnapshot {
        let load = |value: &AtomicU64| value.load(Ordering::Relaxed);
        IoPerformanceSnapshot {
            read_ops: load(&self.read_ops),
            read_bytes: load(&self.read_bytes),
            write_ops: load(&self.write_ops),
            write_bytes: load(&self.write_bytes),
            device_read_ns: load(&self.device_read_ns),
            device_write_ns: load(&self.device_write_ns),
            crypto_read_ns: load(&self.crypto_read_ns),
            crypto_write_ns: load(&self.crypto_write_ns),
            sync_ops: load(&self.sync_ops),
            sync_ns: load(&self.sync_ns),
            inflight: load(&self.inflight),
            max_inflight: load(&self.max_inflight),
        }
    }
}

struct InflightGuard<'a>(&'a IoPerformance);

impl Drop for InflightGuard<'_> {
    fn drop(&mut self) {
        self.0.inflight.fetch_sub(1, Ordering::Relaxed);
    }
}

/// EDP SM4-ECB 透明加解密卷。
pub struct EncryptedPartitionIO {
    io: Arc<dyn RawIo>,
    desc: VolumeDescriptor,
    sm4: Sm4Ecb,
    readonly: bool,
    write_locks: [Mutex<()>; 64],
    sync_lock: Mutex<()>,
    write_generation: AtomicU64,
    synced_generation: AtomicU64,
    performance: IoPerformance,
}

impl EncryptedPartitionIO {
    /// 打开透明卷。descriptor 需带 file_key。
    pub fn open(
        io: Arc<dyn RawIo>,
        desc: VolumeDescriptor,
        readonly: bool,
    ) -> Result<Self, CoreError> {
        let key = desc
            .file_key
            .as_ref()
            .ok_or_else(|| CoreError::InvalidInput("descriptor 缺少 file_key".into()))?;
        Ok(Self {
            io,
            sm4: Sm4Ecb::new(key.as_bytes()),
            desc,
            readonly,
            write_locks: std::array::from_fn(|_| Mutex::new(())),
            sync_lock: Mutex::new(()),
            write_generation: AtomicU64::new(0),
            synced_generation: AtomicU64::new(0),
            performance: IoPerformance::default(),
        })
    }

    /// 卷大小（字节）。
    pub fn size(&self) -> u64 {
        self.desc.size_bytes
    }

    /// 只读标记。
    pub fn is_readonly(&self) -> bool {
        self.readonly
    }

    fn range(&self, offset: u64, len: u64) -> Result<(u64, u64), CoreError> {
        if offset
            .checked_add(len)
            .map_or(true, |end| end > self.size())
        {
            return Err(CoreError::InvalidInput(format!(
                "卷访问越界: offset={offset}, size={len}, volume={}",
                self.size()
            )));
        }
        let begin = offset & !(BLOCK_SIZE - 1);
        let end = (offset + len + BLOCK_SIZE - 1) & !(BLOCK_SIZE - 1);
        Ok((begin, end))
    }

    fn pread_cipher(&self, rel_off: u64, out: &mut [u8]) -> Result<(), CoreError> {
        let abs = self.desc.start_bytes() + rel_off;
        self.io.pread_exact(abs, out)?;
        Ok(())
    }

    fn pwrite_cipher(&self, rel_off: u64, data: &[u8]) -> Result<(), CoreError> {
        let abs = self.desc.start_bytes() + rel_off;
        self.io.pwrite_all(abs, data)?;
        Ok(())
    }

    fn lock_write_range(&self, begin: u64, end: u64) -> Vec<MutexGuard<'_, ()>> {
        const STRIPE_BYTES: u64 = 64 * 1024;
        let mut selected = [false; 64];
        let mut cursor = begin;
        while cursor < end {
            selected[((cursor / STRIPE_BYTES) % selected.len() as u64) as usize] = true;
            cursor = cursor.saturating_add(STRIPE_BYTES);
        }
        selected
            .iter()
            .enumerate()
            .filter(|(_, selected)| **selected)
            .map(|(index, _)| self.write_locks[index].lock().unwrap())
            .collect()
    }

    /// 当前卷 I/O 统计。
    pub fn performance_snapshot(&self) -> IoPerformanceSnapshot {
        self.performance.snapshot()
    }

    /// 读明文（任意偏移/长度，自动按 16B 对齐扩展解密）。
    pub fn read(&self, offset: u64, out: &mut [u8]) -> Result<(), CoreError> {
        if out.is_empty() {
            return Ok(());
        }
        let _inflight = self.performance.enter();
        let (begin, end) = self.range(offset, out.len() as u64)?;
        if offset == begin && end == offset + out.len() as u64 {
            let started = Instant::now();
            self.pread_cipher(offset, out)?;
            self.performance
                .device_read_ns
                .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
            let started = Instant::now();
            self.sm4.decrypt_aligned_in_place(out)?;
            self.performance
                .crypto_read_ns
                .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
        } else {
            let mut buffer = vec![0u8; (end - begin) as usize];
            let started = Instant::now();
            self.pread_cipher(begin, &mut buffer)?;
            self.performance
                .device_read_ns
                .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
            let started = Instant::now();
            self.sm4.decrypt_aligned_in_place(&mut buffer)?;
            self.performance
                .crypto_read_ns
                .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
            let start = (offset - begin) as usize;
            out.copy_from_slice(&buffer[start..start + out.len()]);
        }
        self.performance.read_ops.fetch_add(1, Ordering::Relaxed);
        self.performance
            .read_bytes
            .fetch_add(out.len() as u64, Ordering::Relaxed);
        Ok(())
    }

    /// 写明文。
    ///
    /// 16B 对齐整块写走快路径：ECB 各块独立，直接加密写回，免读-改-写
    /// （修复实盘写放大：exFAT 等文件系统写均为 512B 对齐，此前每次写都
    /// 多一次 USB 读+解密，实测拷贝仅 ~8MB/s）。非对齐写才做 RMW。
    pub fn write(&self, offset: u64, data: &[u8]) -> Result<usize, CoreError> {
        if self.readonly {
            return Err(CoreError::InvalidInput("卷以只读模式打开".into()));
        }
        if data.is_empty() {
            return Ok(0);
        }
        let _inflight = self.performance.enter();
        let (begin, end) = self.range(offset, data.len() as u64)?;
        let _guards = self.lock_write_range(begin, end);
        if offset == begin && end == offset + data.len() as u64 {
            // 对齐快路径
            let mut reenc = data.to_vec();
            let started = Instant::now();
            self.sm4.encrypt_aligned_in_place(&mut reenc)?;
            self.performance
                .crypto_write_ns
                .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
            let started = Instant::now();
            self.pwrite_cipher(offset, &reenc)?;
            self.performance
                .device_write_ns
                .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
            self.performance.write_ops.fetch_add(1, Ordering::Relaxed);
            self.performance
                .write_bytes
                .fetch_add(data.len() as u64, Ordering::Relaxed);
            self.write_generation.fetch_add(1, Ordering::Release);
            return Ok(data.len());
        }
        // 非对齐写：读-改-写
        let mut plain = vec![0u8; (end - begin) as usize];
        let started = Instant::now();
        self.pread_cipher(begin, &mut plain)?;
        self.performance
            .device_read_ns
            .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
        let started = Instant::now();
        self.sm4.decrypt_aligned_in_place(&mut plain)?;
        let start = (offset - begin) as usize;
        plain[start..start + data.len()].copy_from_slice(data);
        self.sm4.encrypt_aligned_in_place(&mut plain)?;
        self.performance
            .crypto_write_ns
            .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
        let started = Instant::now();
        self.pwrite_cipher(begin, &plain)?;
        self.performance
            .device_write_ns
            .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
        self.performance.write_ops.fetch_add(1, Ordering::Relaxed);
        self.performance
            .write_bytes
            .fetch_add(data.len() as u64, Ordering::Relaxed);
        self.write_generation.fetch_add(1, Ordering::Release);
        Ok(data.len())
    }

    /// FUSE flush 只需要保证已提交的请求完成；同步实现中无需额外操作。
    pub fn flush(&self) -> Result<(), CoreError> {
        Ok(())
    }

    /// 强制底层介质持久化。
    pub fn sync(&self) -> Result<(), CoreError> {
        let _guard = self.sync_lock.lock().unwrap();
        let generation = self.write_generation.load(Ordering::Acquire);
        if generation == self.synced_generation.load(Ordering::Acquire) {
            return Ok(());
        }
        let started = Instant::now();
        self.io.fsync()?;
        self.synced_generation.store(generation, Ordering::Release);
        self.performance.sync_ops.fetch_add(1, Ordering::Relaxed);
        self.performance
            .sync_ns
            .fetch_add(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
        Ok(())
    }
}

/// 测试与工具用途的内存 RawIo。
pub mod test_util {
    use super::*;

    pub struct MemIo {
        data: Mutex<Vec<u8>>,
        logical_size: u64,
    }

    impl MemIo {
        pub fn new(len: u64) -> Self {
            Self {
                data: Mutex::new(vec![0u8; len as usize]),
                logical_size: len,
            }
        }

        pub fn from(img: Vec<u8>) -> Self {
            let len = img.len() as u64;
            Self {
                data: Mutex::new(img),
                logical_size: len,
            }
        }

        /// 稀疏镜像：实际数据短，但逻辑大小可超过之（越界读返回零填充）。
        pub fn from_with_logical_size(img: Vec<u8>, logical: u64) -> Self {
            Self {
                data: Mutex::new(img),
                logical_size: logical,
            }
        }
    }

    impl RawIo for MemIo {
        fn pread_exact(&self, off: u64, buf: &mut [u8]) -> std::io::Result<()> {
            let d = self.data.lock().unwrap();
            let off = off as usize;
            if off + buf.len() > self.logical_size as usize {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "越界",
                ));
            }
            for (i, b) in buf.iter_mut().enumerate() {
                *b = d.get(off + i).copied().unwrap_or(0);
            }
            Ok(())
        }

        fn pwrite_all(&self, off: u64, data: &[u8]) -> std::io::Result<()> {
            let mut d = self.data.lock().unwrap();
            let off = off as usize;
            if off + data.len() > self.logical_size as usize {
                return Err(std::io::Error::new(std::io::ErrorKind::WriteZero, "越界"));
            }
            if d.len() < off + data.len() {
                d.resize(off + data.len(), 0);
            }
            d[off..off + data.len()].copy_from_slice(data);
            Ok(())
        }

        fn size(&self) -> u64 {
            self.logical_size
        }

        fn fsync(&self) -> std::io::Result<()> {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_util::MemIo;
    use super::*;
    use crate::lba12::VolumeDescriptor;
    use crate::SecretKey16;

    fn make_volume() -> (Arc<MemIo>, EncryptedPartitionIO) {
        let io = Arc::new(MemIo::new(64 * 1024));
        let desc = VolumeDescriptor {
            partition_type: 4,
            start_sector: 8, // 4096B 起
            size_bytes: 32 * 1024,
            algo: 2,
            file_key: Some(SecretKey16::from([0x42u8; 16])),
            password_crc: 0,
            key_crc: 0,
        };
        let vol = EncryptedPartitionIO::open(io.clone(), desc, false).unwrap();
        (io, vol)
    }

    #[test]
    fn aligned_rw_roundtrip() {
        let (_io, vol) = make_volume();
        let data: Vec<u8> = (0..64u8).collect();
        vol.write(0, &data).unwrap();
        let mut out = vec![0u8; 64];
        vol.read(0, &mut out).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn unaligned_rw_does_not_harm_neighbors() {
        let (_io, vol) = make_volume();
        let a: Vec<u8> = (0..32u8).collect();
        vol.write(0, &a).unwrap();
        // 非对齐写（offset 5，len 10，跨两个块内）
        vol.write(5, &[9u8; 10]).unwrap();
        // 校验邻居未被破坏（0..5 与 15..32 保持原值）
        let mut out = vec![0u8; 32];
        vol.read(0, &mut out).unwrap();
        assert_eq!(&out[..5], &a[..5]);
        assert_eq!(&out[5..15], &[9u8; 10]);
        assert_eq!(&out[15..32], &a[15..32]);
    }

    #[test]
    fn out_of_bounds_rejected() {
        let (_io, vol) = make_volume(); // 32KB
        let e = vol.read(32 * 1024 - 4, &mut [0u8; 8]);
        assert!(e.is_err());
        let e = vol.write(32 * 1024, &[1u8]);
        assert!(e.is_err());
    }

    #[test]
    fn readonly_write_rejected() {
        let io = Arc::new(MemIo::new(64 * 1024));
        let desc = VolumeDescriptor {
            partition_type: 4,
            start_sector: 8,
            size_bytes: 32 * 1024,
            algo: 2,
            file_key: Some(SecretKey16::from([0x42u8; 16])),
            password_crc: 0,
            key_crc: 0,
        };
        let vol = EncryptedPartitionIO::open(io, desc, true).unwrap();
        assert!(vol.write(0, &[1, 2, 3]).is_err());
    }

    #[test]
    fn flush_is_not_a_durability_barrier() {
        let (_io, vol) = make_volume();
        vol.flush().unwrap();
        assert_eq!(vol.performance_snapshot().sync_ops, 0);
        vol.write(0, &[7u8; 16]).unwrap();
        vol.sync().unwrap();
        vol.sync().unwrap();
        assert_eq!(vol.performance_snapshot().sync_ops, 1);
    }

    #[test]
    fn independent_ranges_can_run_concurrently() {
        let (_io, vol) = make_volume();
        let vol = Arc::new(vol);
        let barrier = Arc::new(std::sync::Barrier::new(5));
        let threads: Vec<_> = (0..4u64)
            .map(|index| {
                let vol = vol.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    let offset = index * 4096;
                    let data = vec![index as u8 + 1; 4096];
                    vol.write(offset, &data).unwrap();
                    let mut out = vec![0u8; 4096];
                    vol.read(offset, &mut out).unwrap();
                    assert_eq!(out, data);
                })
            })
            .collect();
        barrier.wait();
        for thread in threads {
            thread.join().unwrap();
        }
        let performance = vol.performance_snapshot();
        assert_eq!(performance.write_ops, 4);
        assert_eq!(performance.read_ops, 4);
        assert!(performance.max_inflight >= 2);
    }
}
