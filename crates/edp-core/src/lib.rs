//! # edp-core
//!
//! EDP（VRV/CEMS EdpEDisk）加密 U 盘格式的核心库：纯算法与格式解析层，
//! 零系统副作用、跨平台可测。
//!
//! 模块一览（M1 逐个填充）：
//! - [`crc32`]：裸 CRC32（init=0、poly 0xEDB88320、无 final XOR）与密钥派生
//! - [`xor`]：LBA7 滚动 16 位 XOR 解码（自对称）
//! - [`edp_aes`]：A6B0/A7F0 魔改 AES（EDPSECDISK200709 白化 + counter 掩码）
//! - [`sm4_ecb`]：SM4-ECB 数据分区加解密与 wrapping key
//! - [`lba7`]：LBA7 旧格式密码认证（k0 反推、key8 unwrap）
//! - [`lba11`]：LBA11 PDKB 块解出 device_id
//! - [`lba12`]：LBA12 分区元数据（EDPF 条目、密码双路径解包）
//! - [`device`]：identify_disk 的 device_id 候选生成
//! - [`volume`]：RawIo 抽象与透明加解密随机访问 IO
//! - [`discovery`]：discover_volume 三级候选编排

pub mod crc32;
pub mod device;
pub mod discovery;
pub mod edp_aes;
pub mod lba11;
pub mod lba12;
pub mod lba7;
pub mod qos;
pub mod sm4_ecb;
#[cfg(target_arch = "aarch64")]
mod sm4_fast;
pub mod synthetic;
pub mod volume;
pub mod xor;

/// 库级错误类型。
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    /// 输入长度/对齐不满足算法要求。
    #[error("输入非法: {0}")]
    InvalidInput(String),
    /// 扇区/条目解析失败。
    #[error("格式解析失败: {0}")]
    Parse(String),
    /// 密码或密钥闭环校验失败。
    #[error("校验失败: {0}")]
    Verify(String),
    /// 底层 IO 错误。
    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),
}

/// 16 字节对称密钥的零化包装：Drop 时清零，Debug 输出脱敏。
#[derive(Clone)]
pub struct SecretKey16(pub(crate) [u8; 16]);

impl Drop for SecretKey16 {
    fn drop(&mut self) {
        self.0.fill(0);
    }
}

impl std::fmt::Debug for SecretKey16 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SecretKey16(***)")
    }
}

impl SecretKey16 {
    /// 以字节数组形式取出（调用方负责生命周期，不额外拷贝）。
    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }
}

impl From<[u8; 16]> for SecretKey16 {
    fn from(v: [u8; 16]) -> Self {
        SecretKey16(v)
    }
}

/// 扇区大小（字节）。
pub const SECTOR_SIZE: u64 = 512;
/// SM4/ECB 块大小（字节）。
pub const BLOCK_SIZE: u64 = 16;
