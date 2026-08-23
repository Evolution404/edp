//! 合成 EDP 盘构造（集成测试/开发验证用）。
//!
//! 用黄金数据（真实盘 LBA7/LBA11/LBA12 密文）+ 给定的明文数据区，
//! 产出一个可被 `usbcore probe/mount` 完整处理的加密镜像：
//! - LBA7/LBA11 直接复用真实扇区（密码体系不变）
//! - LBA12 解密后改写 start_sector/size_bytes，重加密（A7F0）
//! - 数据区 = SM4-ECB(file_key) 加密明文

use crate::edp_aes::a7f0_full;
use crate::lba12::{decode_lba12, EDPF_ENTRY_SIZE};
use crate::sm4_ecb::Sm4Ecb;
use crate::CoreError;

/// 合成盘参数。
pub struct SyntheticSpec<'a> {
    /// 真实盘 LBA7 密文（512B）。
    pub lba7_cipher: &'a [u8],
    /// 真实盘 LBA11 密文（512B）。
    pub lba11_cipher: &'a [u8],
    /// 真实盘 LBA12 密文（512B）。
    pub lba12_cipher: &'a [u8],
    /// 目标 device_id（决定 LBA12 加密 key）。
    pub device_id: &'a str,
    /// 密码（决定条目筛选）。
    pub password: &'a str,
    /// 数据分区类型（2 或 4）。
    pub partition_type: u32,
    /// 明文数据区（内部文件系统镜像，长度需 16B 对齐）。
    pub plaintext: &'a [u8],
}

/// 构造合成加密盘镜像。
pub fn build(spec: &SyntheticSpec<'_>) -> Result<Vec<u8>, CoreError> {
    let mut raw12: [u8; 512] = spec
        .lba12_cipher
        .try_into()
        .map_err(|_| CoreError::InvalidInput("LBA12 必须 512 字节".into()))?;
    let mut plain12 = decode_lba12(&raw12, spec.device_id);

    // 扫描明文 slot 找目标条目（不能依赖 parse 结果的位置——Boot 等
    // 被跳过的条目会造成索引错位）
    let mut target_off = None;
    for off in (0..512).step_by(EDPF_ENTRY_SIZE) {
        let e = &plain12[off..off + EDPF_ENTRY_SIZE];
        if e[..4] != *b"EDPF" {
            break;
        }
        let pt = u32::from_le_bytes(e[0x0C..0x10].try_into().unwrap());
        if pt == spec.partition_type {
            target_off = Some(off);
            break;
        }
    }
    let off = target_off.ok_or_else(|| CoreError::InvalidInput("LBA12 无目标分区条目".into()))?;
    let file_key = crate::lba12::derive_file_key(
        &plain12[off..off + EDPF_ENTRY_SIZE],
        spec.password.as_bytes(),
    )
    .ok_or_else(|| CoreError::InvalidInput("目标条目 file_key 不闭环".into()))?;

    // 改写 start=13 / size=plaintext.len()
    plain12[off + 0x18..off + 0x20].copy_from_slice(&13u64.to_le_bytes());
    plain12[off + 0x28..off + 0x30].copy_from_slice(&(spec.plaintext.len() as u64).to_le_bytes());

    // 重加密 LBA12
    let key = crate::crc32::crc_key(spec.device_id);
    raw12.copy_from_slice(&a7f0_full(&plain12, &key, 0));

    // 加密数据区
    if spec.plaintext.len() % 16 != 0 {
        return Err(CoreError::InvalidInput("明文数据区必须 16 字节对齐".into()));
    }
    let sm4 = Sm4Ecb::new(file_key.as_bytes());
    let cipher_data = sm4.encrypt_aligned(spec.plaintext)?;

    // 拼装：13 扇区头 + 密文数据
    let mut img = vec![0u8; 13 * 512];
    img[7 * 512..8 * 512].copy_from_slice(spec.lba7_cipher);
    img[11 * 512..12 * 512].copy_from_slice(spec.lba11_cipher);
    img[12 * 512..13 * 512].copy_from_slice(&raw12);
    img.extend_from_slice(&cipher_data);
    Ok(img)
}
