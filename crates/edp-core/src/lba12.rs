//! LBA12 新格式分区元数据（EDPF 0x60B 条目 ×最多 8）。
//!
//! 解密：A6B0，key = `LE32(crc32_bare(device_id))`。
//! file_key 解包按**密码双路径**：
//! - 路径A（默认密码 0000aaaa / 制盘状态，三盘实测闭合）：
//!   `file_key = SM4_Decrypt(salt16, MD5("LtSWi[2f)j"))`，与密码无关；
//!   密码校验仅 `crc32_bare(password) == entry+0x30`
//! - 路径B（用户修改密码后，待改密盘实测校准）：
//!   按 UserLogin 逆向（key_material = 用户密码）：
//!   `candidate = SM4_Decrypt(salt16, MD5(password))`，
//!   `crc32_bare(candidate) == entry+0x34` 闭环即成功

use crate::crc32::crc32_bare;
use crate::edp_aes::a6b0_full;
use crate::sm4_ecb::{wrapping_key, Sm4Ecb};
use crate::{CoreError, SecretKey16, SECTOR_SIZE};

/// EDPF 条目大小（LBA12 新格式）。
pub const EDPF_ENTRY_SIZE: usize = 0x60;

/// 解密 LBA12 扇区（A6B0，key 来自 device_id 的 CRC）。
pub fn decode_lba12(raw: &[u8; 512], device_id: &str) -> [u8; 512] {
    let key = crate::crc32::crc_key(device_id);
    a6b0_full(raw, &key, 0)
        .try_into()
        .expect("a6b0_full 输出长度不变")
}

/// EDP 数据分区描述符（密钥材料 `file_key` 脱敏）。
#[derive(Clone)]
pub struct VolumeDescriptor {
    /// 1=Boot（明文公共区，无数据密钥）2=Share 4=Encrypt。
    pub partition_type: u32,
    pub start_sector: u64,
    pub size_bytes: u64,
    pub algo: u32,
    pub file_key: Option<SecretKey16>,
    pub password_crc: u32,
    pub key_crc: u32,
}

impl VolumeDescriptor {
    /// 起始字节偏移。
    pub fn start_bytes(&self) -> u64 {
        self.start_sector * SECTOR_SIZE
    }

    /// 对外可序列化视图（绝不包含 file_key）。
    pub fn public_dict(&self) -> serde_json::Value {
        serde_json::json!({
            "partition_type": self.partition_type,
            "start_sector": self.start_sector,
            "start_bytes": self.start_bytes(),
            "size_bytes": self.size_bytes,
            "algo": self.algo,
            "password_crc": format!("{:08x}", self.password_crc),
            "key_crc": format!("{:08x}", self.key_crc),
        })
    }
}

impl std::fmt::Debug for VolumeDescriptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolumeDescriptor")
            .field("partition_type", &self.partition_type)
            .field("start_sector", &self.start_sector)
            .field("size_bytes", &self.size_bytes)
            .field("algo", &self.algo)
            .field("file_key", &self.file_key.as_ref().map(|_| "***"))
            .field("password_crc", &format!("{:08x}", self.password_crc))
            .field("key_crc", &format!("{:08x}", self.key_crc))
            .finish()
    }
}

/// 单条 entry 的 file_key 双路径解包：成功返回 16B 密钥。
///
/// 先路径A（固定种子 + 密码 CRC 前置校验），失败走路径B（MD5(password) 解 salt
/// + CRC 闭环）。任一闭环即成功。
pub fn derive_file_key(entry: &[u8], password: &[u8]) -> Option<SecretKey16> {
    let salt: [u8; 16] = entry[0x38..0x48].try_into().ok()?;
    let stored_key_crc = u32::from_le_bytes(entry[0x34..0x38].try_into().ok()?);
    let stored_pwd_crc = u32::from_le_bytes(entry[0x30..0x34].try_into().ok()?);
    let sm4_fixed = Sm4Ecb::new(&wrapping_key());

    // 路径A：默认密码/制盘状态。密码 CRC 匹配 + 固定种子解出闭环 file_key。
    if stored_pwd_crc == crc32_bare(password) {
        if let Ok(fk) = sm4_fixed.decrypt_aligned(&salt) {
            if crc32_bare(&fk) == stored_key_crc {
                let arr: [u8; 16] = fk.try_into().unwrap();
                return Some(SecretKey16::from(arr));
            }
        }
    }

    // TODO(real-disk): 路径B（修改后密码）待改密盘实测校准——
    // 按逆向（UserLogin key_material=密码）推测 salt 被新密码重新 wrap：
    // candidate = SM4_Decrypt(salt, MD5(password))，CRC 闭环即真。
    use md5::Digest;
    let mut h = md5::Md5::new();
    h.update(password);
    let dk: [u8; 16] = h.finalize().into();
    let sm4_pwd = Sm4Ecb::new(&dk);
    if let Ok(cand) = sm4_pwd.decrypt_aligned(&salt) {
        if crc32_bare(&cand) == stored_key_crc {
            let arr: [u8; 16] = cand.try_into().unwrap();
            return Some(SecretKey16::from(arr));
        }
    }
    None
}

/// 解析 LBA12 明文的 EDPF 条目（密码不匹配的受保护条目被跳过）。
pub fn parse_lba12_entries(
    plain: &[u8; 512],
    password: &[u8],
) -> Result<Vec<VolumeDescriptor>, CoreError> {
    let password_crc = crc32_bare(password);
    let mut out = Vec::new();
    for off in (0..SECTOR_SIZE as usize).step_by(EDPF_ENTRY_SIZE) {
        let entry = &plain[off..off + EDPF_ENTRY_SIZE];
        if entry[..4] != *b"EDPF" {
            break;
        }
        let partition_type = u32::from_le_bytes(entry[0x0C..0x10].try_into().unwrap());
        let start_sector = u64::from_le_bytes(entry[0x18..0x20].try_into().unwrap());
        let size_bytes = u64::from_le_bytes(entry[0x28..0x30].try_into().unwrap());
        let (stored_pwd_crc, key_crc) = {
            let p = u32::from_le_bytes(entry[0x30..0x34].try_into().unwrap());
            let k = u32::from_le_bytes(entry[0x34..0x38].try_into().unwrap());
            (p, k)
        };
        let algo = u32::from_le_bytes(entry[0x58..0x5C].try_into().unwrap());
        if ![1, 2, 4].contains(&partition_type) {
            return Err(CoreError::Parse(format!(
                "LBA12 分区类型非法: {partition_type}"
            )));
        }
        // 密码 CRC 非零且不匹配 → 该条目密码不同，跳过。
        if stored_pwd_crc != 0 && stored_pwd_crc != password_crc {
            // 路径B 的闭环在 derive_file_key 中处理，但 CRC 前置过滤
            // 会拦截改密盘条目——此处放行“CRC 不匹配但双路径可解”的场景
            // 由调用方（discovery）负责；本函数仍按 Python 语义保留过滤。
            continue;
        }
        if partition_type == 1 {
            // Boot 公共区无数据加密 key，不作为透明卷候选。
            continue;
        }
        if algo != 2 {
            // 改进（对比 Python 参考实现）：无密码且无 key CRC 的条目是
            // 公共区性质（aigo 实测：type=2/algo=0/pwd_crc=0/key_crc=0），
            // 没有任何密钥材料可解，跳过而非报错——否则整盘被单条目废掉。
            if stored_pwd_crc == 0 && key_crc == 0 {
                continue;
            }
            return Err(CoreError::Parse(format!(
                "当前仅支持已验证的 EDP SM4 模式，entry algo={algo}"
            )));
        }
        let file_key = derive_file_key(entry, password);
        if file_key.is_none() {
            return Err(CoreError::Verify(format!(
                "type={partition_type} 的 file_key 双路径均不闭环"
            )));
        }
        if start_sector == 0 || size_bytes == 0 || size_bytes % SECTOR_SIZE != 0 {
            return Err(CoreError::Parse(format!(
                "type={partition_type} 的分区边界非法"
            )));
        }
        out.push(VolumeDescriptor {
            partition_type,
            start_sector,
            size_bytes,
            algo,
            file_key,
            password_crc: stored_pwd_crc,
            key_crc,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 路径B 自洽：用 MD5(password) 构造 wrapped salt，验证闭环解包。
    /// （真实改密盘数据待采集后校准，见 TODO(real-disk)）
    #[test]
    fn path_b_synthetic_closure() {
        use md5::Digest;
        let password = b"userpwd1";
        let real_key: [u8; 16] = (0u8..16).map(|i| i * 11 + 3).collect::<Vec<u8>>()[..]
            .try_into()
            .unwrap();
        let mut h = md5::Md5::new();
        h.update(password);
        let dk: [u8; 16] = h.finalize().into();
        let salt = Sm4Ecb::new(&dk).encrypt_aligned(&real_key).unwrap();

        let mut entry = [0u8; EDPF_ENTRY_SIZE];
        entry[..4].copy_from_slice(b"EDPF");
        // stored_pwd_crc 填一个与默认密码不匹配的值（模拟改密盘）
        entry[0x30..0x34].copy_from_slice(&0xdead_beefu32.to_le_bytes());
        entry[0x34..0x38].copy_from_slice(&crc32_bare(&real_key).to_le_bytes());
        entry[0x38..0x48].copy_from_slice(&salt);

        let got = derive_file_key(&entry, password).expect("路径B 应闭环");
        assert_eq!(got.as_bytes(), &real_key);
    }

    /// 路径A：真实盘 salt + 默认密码走固定种子路径。
    #[test]
    fn path_a_lexar_salt() {
        let salt: [u8; 16] = hex_literal::hex!("56fd7c10288df7fd8752dc94bb2d5eee");
        let mut entry = [0u8; EDPF_ENTRY_SIZE];
        entry[..4].copy_from_slice(b"EDPF");
        entry[0x30..0x34].copy_from_slice(&0x0429_735du32.to_le_bytes());
        entry[0x34..0x38].copy_from_slice(&0x418c_1a0cu32.to_le_bytes());
        entry[0x38..0x48].copy_from_slice(&salt);
        let got = derive_file_key(&entry, b"0000aaaa").expect("路径A 应闭环");
        assert_eq!(
            hex::encode(got.as_bytes()),
            "1a28e58ce2c0e3eb16877ad38586f2e2"
        );
    }
}
