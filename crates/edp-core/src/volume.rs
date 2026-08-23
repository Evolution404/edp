//! 透明加解密随机访问 IO：把 EDP SM4-ECB 分区映射为任意偏移读写的明文卷。
//!
//! 语义与 `edp_volume.py::EncryptedPartitionIO` 逐行对应：
//! - 读：扩展到 16B 边界解密后切片
//! - 写：读-改-写（RMW）非对齐部分，重加密整个边界范围
//! - 互斥锁保护；flush 下传 fsync

use std::fs::OpenOptions;
use std::io::SeekFrom;
use std::path::Path;
use std::sync::{Arc, Mutex};

use crate::lba12::VolumeDescriptor;
use crate::sm4_ecb::Sm4Ecb;
use crate::{CoreError, BLOCK_SIZE};

/// 底层随机访问抽象（真实设备 / 镜像文件 / 测试内存）。
pub trait RawIo: Send + Sync {
    fn pread_exact(&self, off: u64, buf: &mut [u8]) -> std::io::Result<()>;
    fn pwrite_all(&self, off: u64, data: &[u8]) -> std::io::Result<()>;
    fn size(&self) -> u64;
    fn fsync(&self) -> std::io::Result<()>;
}

/// 镜像文件 / 整盘 `/dev/rdiskN` 的实现（read+write 双向打开）。
pub struct FileRawIo {
    file: std::sync::Mutex<std::fs::File>,
    path: std::path::PathBuf,
    size: u64,
}

impl FileRawIo {
    /// 以指定模式打开（readonly=true 时 O_RDONLY）。
    pub fn open(path: &Path, readonly: bool) -> std::io::Result<Self> {
        let file = OpenOptions::new().read(true).write(!readonly).open(path)?;
        let size = if path.starts_with("/dev/") {
            // 块设备的 st_size 不可靠，用 seek End 取容量。
            use std::io::Seek;
            let mut f = &file;
            f.seek(SeekFrom::End(0)).unwrap_or(0)
        } else {
            file.metadata()?.len()
        };
        Ok(Self {
            file: Mutex::new(file),
            path: path.to_path_buf(),
            size,
        })
    }

    /// 底层路径（诊断用）。
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl RawIo for FileRawIo {
    fn pread_exact(&self, off: u64, buf: &mut [u8]) -> std::io::Result<()> {
        use std::os::unix::fs::FileExt;
        let f = self.file.lock().unwrap();
        f.read_exact_at(buf, off)
    }

    fn pwrite_all(&self, off: u64, data: &[u8]) -> std::io::Result<()> {
        use std::os::unix::fs::FileExt;
        let f = self.file.lock().unwrap();
        f.write_all_at(data, off)
    }

    fn size(&self) -> u64 {
        self.size
    }

    fn fsync(&self) -> std::io::Result<()> {
        let f = self.file.lock().unwrap();
        f.sync_all()
    }
}

/// EDP SM4-ECB 透明加解密卷。
pub struct EncryptedPartitionIO {
    io: Arc<dyn RawIo>,
    desc: VolumeDescriptor,
    sm4: Sm4Ecb,
    readonly: bool,
    lock: Mutex<()>,
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
            lock: Mutex::new(()),
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

    /// 读明文（任意偏移/长度，自动按 16B 对齐扩展解密）。
    pub fn read(&self, offset: u64, out: &mut [u8]) -> Result<(), CoreError> {
        if out.is_empty() {
            return Ok(());
        }
        let (begin, end) = self.range(offset, out.len() as u64)?;
        let _guard = self.lock.lock().unwrap();
        let mut cipher = vec![0u8; (end - begin) as usize];
        self.pread_cipher(begin, &mut cipher)?;
        let plain = self.sm4.decrypt_aligned(&cipher)?;
        let start = (offset - begin) as usize;
        out.copy_from_slice(&plain[start..start + out.len()]);
        Ok(())
    }

    /// 写明文（RMW：读边界块 → 解密 → 改 → 重加密写回）。
    pub fn write(&self, offset: u64, data: &[u8]) -> Result<usize, CoreError> {
        if self.readonly {
            return Err(CoreError::InvalidInput("卷以只读模式打开".into()));
        }
        if data.is_empty() {
            return Ok(0);
        }
        let (begin, end) = self.range(offset, data.len() as u64)?;
        let _guard = self.lock.lock().unwrap();
        let mut cipher = vec![0u8; (end - begin) as usize];
        self.pread_cipher(begin, &mut cipher)?;
        let mut plain = self.sm4.decrypt_aligned(&cipher)?;
        let start = (offset - begin) as usize;
        plain[start..start + data.len()].copy_from_slice(data);
        let reenc = self.sm4.encrypt_aligned(&plain)?;
        self.pwrite_cipher(begin, &reenc)?;
        Ok(data.len())
    }

    /// fsync 下传。
    pub fn flush(&self) -> Result<(), CoreError> {
        let _guard = self.lock.lock().unwrap();
        self.io.fsync()?;
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
}
