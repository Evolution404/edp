//! SM4 分组密码（GB/T 32907-2016）+ ECB 模式。
//!
//! 使用 RustCrypto 维护的底层实现，并提供原地批量接口。卷 I/O 的热路径
//! 通过原地接口避免为每个请求额外分配一份明文或密文。

use crate::CoreError;
use rayon::prelude::*;
use sm4::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};

// macFUSE / DiskImages 在实机上把 iBoysoft NTFS 顺序 I/O 拆成约 64 KiB
// 请求；阈值必须低于该尺寸，否则每个请求都会退化为约 80 MB/s 的单核 SM4。
const PARALLEL_THRESHOLD: usize = 32 * 1024;
const PARALLEL_CHUNK: usize = 8 * 1024;

fn crypto_pool() -> &'static rayon::ThreadPool {
    static POOL: std::sync::OnceLock<rayon::ThreadPool> = std::sync::OnceLock::new();
    POOL.get_or_init(|| {
        let workers = std::thread::available_parallelism()
            // 单核 SM4 远低于 USB 3.x 上限，批量 ECB 块相互独立。
            // 最多用 8 个核，使加解密能力高于介质带宽，但不占满整机。
            .map(|value| value.get().min(8))
            .unwrap_or(2);
        rayon::ThreadPoolBuilder::new()
            .num_threads(workers)
            .thread_name(|index| format!("edp-sm4-{index}"))
            .start_handler(|_| crate::qos::set_current_thread_user_initiated())
            .build()
            .expect("创建 SM4 工作线程池失败")
    })
}

/// SM4-ECB：持密钥的加解密器（输入必须 16 字节对齐）。
#[derive(Clone)]
pub struct Sm4Ecb(sm4::Sm4);

impl Sm4Ecb {
    /// 以 16 字节密钥构造。
    pub fn new(key: &[u8; 16]) -> Self {
        Self(sm4::Sm4::new(key.into()))
    }

    fn encrypt_chunk(&self, data: &mut [u8]) {
        for chunk in data.chunks_exact_mut(16) {
            self.0.encrypt_block(chunk.into());
        }
    }

    fn decrypt_chunk(&self, data: &mut [u8]) {
        for chunk in data.chunks_exact_mut(16) {
            self.0.decrypt_block(chunk.into());
        }
    }

    fn check_aligned(data: &[u8]) -> Result<(), CoreError> {
        if data.len() % 16 != 0 {
            return Err(CoreError::InvalidInput(format!(
                "SM4-ECB 输入必须 16 字节对齐，实际 {}",
                data.len()
            )));
        }
        Ok(())
    }

    /// 原地 ECB 加密。
    pub fn encrypt_aligned_in_place(&self, data: &mut [u8]) -> Result<(), CoreError> {
        Self::check_aligned(data)?;
        if data.len() >= PARALLEL_THRESHOLD {
            crypto_pool().install(|| {
                data.par_chunks_mut(PARALLEL_CHUNK)
                    .for_each(|chunk| self.encrypt_chunk(chunk));
            });
        } else {
            self.encrypt_chunk(data);
        }
        Ok(())
    }

    /// 原地 ECB 解密。
    pub fn decrypt_aligned_in_place(&self, data: &mut [u8]) -> Result<(), CoreError> {
        Self::check_aligned(data)?;
        if data.len() >= PARALLEL_THRESHOLD {
            crypto_pool().install(|| {
                data.par_chunks_mut(PARALLEL_CHUNK)
                    .for_each(|chunk| self.decrypt_chunk(chunk));
            });
        } else {
            self.decrypt_chunk(data);
        }
        Ok(())
    }

    /// ECB 加密（对齐输入）。
    pub fn encrypt_aligned(&self, data: &[u8]) -> Result<Vec<u8>, CoreError> {
        let mut out = data.to_vec();
        self.encrypt_aligned_in_place(&mut out)?;
        Ok(out)
    }

    /// ECB 解密（对齐输入）。
    pub fn decrypt_aligned(&self, data: &[u8]) -> Result<Vec<u8>, CoreError> {
        let mut out = data.to_vec();
        self.decrypt_aligned_in_place(&mut out)?;
        Ok(out)
    }
}

/// file_key 解包的固定 wrapping key：MD5(b"LtSWi[2f)j")。
pub fn wrapping_key() -> [u8; 16] {
    use md5::Digest;
    let mut h = md5::Md5::new();
    h.update(b"LtSWi[2f)j");
    h.finalize().into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    /// GB/T 32907-2016 标准向量：
    /// 明文 0123456789abcdeffedcba9876543210
    /// 密钥 0123456789abcdeffedcba9876543210
    /// 密文 681edf34d206965e86b3e94f536e4246
    #[test]
    fn standard_vector() {
        let key: [u8; 16] = hex!("0123456789abcdeffedcba9876543210");
        let pt: [u8; 16] = hex!("0123456789abcdeffedcba9876543210");
        let expect: [u8; 16] = hex!("681edf34d206965e86b3e94f536e4246");
        let sm4 = Sm4Ecb::new(&key);
        assert_eq!(sm4.encrypt_aligned(&pt).unwrap(), expect);
        assert_eq!(sm4.decrypt_aligned(&expect).unwrap(), pt);
    }

    /// 真实 Lexar 盘 file_key 解包闭环（EDPF.md §4 实测）：
    /// SM4_Decrypt(56fd7c10288df7fd8752dc94bb2d5eee, MD5("LtSWi[2f)j"))
    /// = 1a28e58ce2c0e3eb16877ad38586f2e2
    #[test]
    fn lexar_file_key_unwrap() {
        let salt: [u8; 16] = hex!("56fd7c10288df7fd8752dc94bb2d5eee");
        let expect: [u8; 16] = hex!("1a28e58ce2c0e3eb16877ad38586f2e2");
        let sm4 = Sm4Ecb::new(&wrapping_key());
        assert_eq!(sm4.decrypt_aligned(&salt).unwrap(), expect);
    }

    /// 非对齐输入必须报错。
    #[test]
    fn misaligned_rejected() {
        let sm4 = Sm4Ecb::new(&[0u8; 16]);
        assert!(sm4.encrypt_aligned(&[0u8; 15]).is_err());
    }
}
