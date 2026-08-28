//! crypto_vectors.rs — 与 Python 版逐字节对拍(向量由 tools/gen_vectors.py 生成,
//! 含真实盘 LBA4/6/7/8/9/11/12 的 raw↔dec 对与全部 key 参数)。

use edpopen_lib::crypto::*;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
        .collect()
}

#[test]
fn all_disks_all_sectors_match_python() {
    let v: serde_json::Value =
        serde_json::from_str(include_str!("vectors.json")).expect("vectors.json 缺失, 先跑 tools/gen_vectors.py");
    let disks = v["disks"].as_array().expect("vectors 结构错误");
    assert!(!disks.is_empty());

    for disk in disks {
        let name = disk["name"].as_str().unwrap();
        let device_id = disk["device_id"].as_str().unwrap();

        // key 派生对拍
        let crc = crc32_bare(device_id.as_bytes());
        assert_eq!(format!("{crc:08X}"), disk["crc32"].as_str().unwrap(), "{name} CRC32");
        let k0 = ((crc & 0xFFFF) ^ ((crc >> 16) & 0xFFFF)) as u16;
        assert_eq!(format!("{k0:04X}"), disk["lba7_k0"].as_str().unwrap(), "{name} K0");
        let crc_key = crc.to_le_bytes();

        let lba11_key: Option<Vec<u8>> = disk["lba11_key"]
            .as_str()
            .map(unhex);

        for (lba, sec) in disk["sectors"].as_object().unwrap() {
            let raw = unhex(sec["raw_hex"].as_str().unwrap());
            let expect: Vec<u8> = match sec["dec_hex"].as_str() {
                Some(h) => unhex(h),
                None => continue,                      // LBA11 双口径失败的盘跳过
            };
            let got: Vec<u8> = match lba.as_str() {
                "4" => lba4_decode(&raw).expect("{name} LBA4 serial").0,
                "6" => lba6_decode(&raw),
                "7" => xor_rolling(&raw, k0),
                "8" => {
                    let mut d = a6b0_full(&raw[..0x170], &crc_key, 0);
                    d.extend_from_slice(&[0u8; 144]);  // read_metadata 口径: 尾 144B 零填充
                    d
                }
                "9" => {
                    let mut d = a6b0_full(&raw[..0x80], &crc_key, 0);
                    d.extend_from_slice(&[0u8; 128]);
                    d.extend(raw[0x100..0x120].iter().map(|b| b ^ 0x88));
                    d.extend_from_slice(&[0u8; 224]);
                    d
                }
                "11" => {
                    let key = lba11_key.as_ref().unwrap();
                    let mut d = raw[..0x100].to_vec(); // rand 头明文
                    d.extend_from_slice(&a6b0_full(&raw[0x100..], key, 0));
                    d
                }
                "12" => {
                    let mut d = a6b0_full(&raw[..0x170], &crc_key, 0);
                    d.extend_from_slice(&raw[0x170..]); // 尾 144B raw 原样
                    d
                }
                _ => continue,
            };
            assert_eq!(got.len(), 512, "{name} LBA{lba} 长度");
            assert_eq!(got, expect, "{name} LBA{lba} 与 Python 解密结果不一致");
        }
    }
}

/// 加密感知保存的核心路径: 解密明文 → a7f0 重加密 → 还原原始密文
#[test]
fn reencrypt_reproduces_raw() {
    let v: serde_json::Value = serde_json::from_str(include_str!("vectors.json")).unwrap();
    for disk in v["disks"].as_array().unwrap() {
        let name = disk["name"].as_str().unwrap();
        let crc = crc32_bare(disk["device_id"].as_str().unwrap().as_bytes());
        let crc_key = crc.to_le_bytes();
        let k0 = ((crc & 0xFFFF) ^ ((crc >> 16) & 0xFFFF)) as u16;

        // LBA12: 前 368B
        let raw12 = unhex(disk["sectors"]["12"]["raw_hex"].as_str().unwrap());
        let dec12 = a6b0_full(&raw12[..0x170], &crc_key, 0);
        assert_eq!(a7f0_full(&dec12, &crc_key, 0), &raw12[..0x170], "{name} LBA12 重加密");

        // LBA7: 整扇滚动 XOR 自逆
        let raw7 = unhex(disk["sectors"]["7"]["raw_hex"].as_str().unwrap());
        assert_eq!(xor_rolling(&xor_rolling(&raw7, k0), k0), raw7, "{name} LBA7 往返");

        // LBA6: 解密→重加密→校验和
        let raw6 = unhex(disk["sectors"]["6"]["raw_hex"].as_str().unwrap());
        let dec6 = lba6_decode(&raw6);
        let re = xor_rolling(&dec6[..0x1FC], LBA6_K0);
        assert_eq!(&re[..], &raw6[..0x1FC], "{name} LBA6 重加密");
        assert_eq!(lba6_checksum(&re), u32::from_le_bytes(raw6[0x1FC..].try_into().unwrap()),
            "{name} LBA6 校验和与盘上一致");
    }
}
