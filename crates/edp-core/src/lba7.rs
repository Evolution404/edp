//! LBA7 旧格式密码认证（EDPF 0x40B 条目 ×8）。
//!
//! 解密：从密文首 word 反推 K0（`word0 ^ u16_le("ED")` 的明文必为 `EDPF`
//! 头两个字节），再滚动 XOR 整扇区——不依赖 device_id，比按 device_id
//! 派生 K0 更鲁棒。对照 `edp_usb.py::recover_lba7/verify_password`。

use crate::crc32::crc32_bare;
use crate::xor::xor_decode_copy;
use crate::CoreError;

/// algo=0 旧格式密码 hash：密码按 little-endian DWORD 求和（mod 2^32）。
pub fn old_hash(password: &[u8]) -> u32 {
    let mut total: u32 = 0;
    for chunk in password.chunks(4) {
        let mut buf = [0u8; 4];
        buf[..chunk.len()].copy_from_slice(chunk);
        total = total.wrapping_add(u32::from_le_bytes(buf));
    }
    total
}

/// algo=0 key8 解包：wrapped8 的两个 DWORD 分别 XOR old_hash(password)。
pub fn unwrap_key8(password: &[u8], wrapped8: &[u8; 8]) -> [u8; 8] {
    let h = old_hash(password);
    let lo = u32::from_le_bytes(wrapped8[0..4].try_into().unwrap()) ^ h;
    let hi = u32::from_le_bytes(wrapped8[4..8].try_into().unwrap()) ^ h;
    let mut out = [0u8; 8];
    out[0..4].copy_from_slice(&lo.to_le_bytes());
    out[4..8].copy_from_slice(&hi.to_le_bytes());
    out
}

/// 从 LBA7 密文恢复 (k0, 明文)；明文头不是 EDPF 则报错。
pub fn recover_lba7(raw: &[u8; 512]) -> Result<(u16, Vec<u8>), CoreError> {
    let raw_word = u16::from_le_bytes([raw[0], raw[1]]);
    let ed = u16::from_le_bytes(*b"ED");
    let k0 = raw_word ^ ed;
    let plain = xor_decode_copy(raw, k0);
    if plain[..4] != *b"EDPF" {
        return Err(CoreError::Parse(
            "LBA7 不是可识别的 EDPF old-format 扇区".into(),
        ));
    }
    Ok((k0, plain))
}

/// 单条 LBA7 EDPF 条目的认证报告。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Lba7Entry {
    pub index: usize,
    pub partition_type: u32,
    pub start_sector: u64,
    pub size_bytes: u64,
    pub protected: bool,
    pub password_crc_ok: bool,
    pub key_crc_ok: bool,
    pub ok: bool,
}

/// 整扇区认证报告。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Lba7Report {
    pub authenticated: bool,
    pub lba7_k0: String,
    pub matched_entries: Vec<usize>,
    pub entries: Vec<Lba7Entry>,
}

/// 验证密码：密码 CRC 匹配 + key8 CRC 闭环。
pub fn verify_password(raw_lba7: &[u8; 512], password: &str) -> Result<Lba7Report, CoreError> {
    let (k0, plain) = recover_lba7(raw_lba7)?;
    let pwd = password.as_bytes();
    let pwd_crc = crc32_bare(pwd);
    let mut entries = Vec::new();
    let mut matched = Vec::new();
    for index in 0..8 {
        let off = index * 0x40;
        let entry = &plain[off..off + 0x40];
        if entry[..4] != *b"EDPF" {
            break;
        }
        let stored_pwd_crc = u32::from_le_bytes(entry[0x30..0x34].try_into().unwrap());
        let stored_key_crc = u32::from_le_bytes(entry[0x34..0x38].try_into().unwrap());
        let wrapped8: [u8; 8] = entry[0x38..0x40].try_into().unwrap();
        let has_wrapped = wrapped8.iter().any(|&b| b != 0);
        let protected = stored_pwd_crc != 0 || has_wrapped;
        let password_crc_ok = protected && stored_pwd_crc == pwd_crc;
        let key_crc_ok = if password_crc_ok && has_wrapped {
            let key8 = unwrap_key8(pwd, &wrapped8);
            crc32_bare(&key8) == stored_key_crc
        } else {
            false
        };
        let ok = password_crc_ok && (!has_wrapped || key_crc_ok);
        entries.push(Lba7Entry {
            index,
            partition_type: u32::from_le_bytes(entry[0x0C..0x10].try_into().unwrap()),
            start_sector: u64::from_le_bytes(entry[0x18..0x20].try_into().unwrap()),
            size_bytes: u64::from_le_bytes(entry[0x28..0x30].try_into().unwrap()),
            protected,
            password_crc_ok,
            key_crc_ok,
            ok,
        });
        if ok {
            matched.push(index);
        }
    }
    Ok(Lba7Report {
        authenticated: !matched.is_empty(),
        lba7_k0: format!("{k0:#x}"),
        matched_entries: matched,
        entries,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_hash_known_value() {
        // EDPF.md §4 实测：old_hash("0000aaaa") = 0x91919191
        assert_eq!(old_hash(b"0000aaaa"), 0x9191_9191);
    }

    #[test]
    fn old_hash_padding() {
        // 长度非 4 倍数时零填充：b"abc" → [0,0,0,'a']? 不，小端打包为 'a','b','c',0
        assert_eq!(old_hash(b"abc"), u32::from_le_bytes([b'a', b'b', b'c', 0]));
        assert_eq!(old_hash(b""), 0);
    }

    #[test]
    fn unwrap_key8_lexar_closure() {
        // EDPF.md §4 实测闭环：wrapped8 = 4cd18872f2eca89e + 0000aaaa
        // → key8 = dd4019e3637d390f，CRC32 = 0x793fcb2d
        let wrapped8: [u8; 8] = [0x4c, 0xd1, 0x88, 0x72, 0xf2, 0xec, 0xa8, 0x9e];
        let key8 = unwrap_key8(b"0000aaaa", &wrapped8);
        assert_eq!(hex::encode(key8), "dd4019e3637d390f");
        assert_eq!(crc32_bare(&key8), 0x793f_cb2d);
    }

    /// 真实盘 LBA7 用黄金数据验证（0000aaaa 认证通过）。
    #[test]
    fn golden_lba7_auth() {
        let disks: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../fixtures/golden/disks.json"
            ))
            .unwrap(),
        )
        .unwrap();
        for d in disks["disks"].as_array().unwrap() {
            let name = d["name"].as_str().unwrap();
            if d["password"].as_str().unwrap() != "0000aaaa" {
                continue;
            }
            let raw: [u8; 512] = hex::decode(d["lba7"]["cipher_hex"].as_str().unwrap())
                .unwrap()
                .try_into()
                .unwrap();
            let report = verify_password(&raw, "0000aaaa").unwrap();
            if name == "old_aigo" {
                // aigo 的 LBA7 密码体系未启用（EDPF.md §8：entry1/2 compact key 全零）
                assert!(
                    !report.authenticated,
                    "{name} 未启用 LBA7 密码体系，不应认证通过"
                );
                continue;
            }
            assert!(report.authenticated, "{name} 应认证通过");
            // 错误密码拒绝
            let bad = verify_password(&raw, "631770").unwrap();
            assert!(!bad.authenticated, "{name} 错误密码应被拒");
        }
    }
}
