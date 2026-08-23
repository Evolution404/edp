//! 黄金数据全量对照测试：fixtures/golden/{disks,vectors}.json
//! 由 Python 参考实现在开发期一次性离线生成（项目本身零 Python 依赖）。

use edp_core::crc32::crc32_bare;
use edp_core::edp_aes::{a6b0_full, a7f0_full};
use edp_core::sm4_ecb::Sm4Ecb;
use edp_core::xor::xor_decode_copy;
use serde_json::Value;

fn golden_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/golden")
}

fn load(name: &str) -> Value {
    let path = golden_dir().join(name);
    serde_json::from_str(&std::fs::read_to_string(path).expect("读取黄金数据")).expect("解析 JSON")
}

fn unhex(s: &str) -> Vec<u8> {
    hex::decode(s).expect("hex 解码")
}

// ---------- vectors.json ----------

#[test]
fn golden_crc32_vectors() {
    for v in load("vectors.json")["crc32_bare"].as_array().unwrap() {
        let got = crc32_bare(&unhex(v["input_hex"].as_str().unwrap()));
        assert_eq!(format!("{got:08x}"), v["expected"].as_str().unwrap());
    }
}

#[test]
fn golden_xor_vectors() {
    for v in load("vectors.json")["xor_8541"].as_array().unwrap() {
        let got = xor_decode_copy(
            &unhex(v["input_hex"].as_str().unwrap()),
            v["k0"].as_u64().unwrap() as u16,
        );
        assert_eq!(hex::encode(got), v["output_hex"].as_str().unwrap());
    }
}

#[test]
fn golden_edp_aes_vectors() {
    for v in load("vectors.json")["edp_aes"].as_array().unwrap() {
        let input = unhex(v["input_hex"].as_str().unwrap());
        let key = unhex(v["key_hex"].as_str().unwrap());
        let ctr = v["counter"].as_u64().unwrap() as u32;
        assert_eq!(
            hex::encode(a6b0_full(&input, &key, ctr)),
            v["a6b0_out_hex"].as_str().unwrap(),
            "a6b0 向量不符 counter={ctr}"
        );
        assert_eq!(
            hex::encode(a7f0_full(&input, &key, ctr)),
            v["a7f0_out_hex"].as_str().unwrap(),
            "a7f0 向量不符 counter={ctr}"
        );
    }
}

#[test]
fn golden_sm4_vectors() {
    for v in load("vectors.json")["sm4_ecb"].as_array().unwrap() {
        let key: [u8; 16] = unhex(v["key_hex"].as_str().unwrap()).try_into().unwrap();
        let input = unhex(v["input_hex"].as_str().unwrap());
        let sm4 = Sm4Ecb::new(&key);
        assert_eq!(
            hex::encode(sm4.encrypt_aligned(&input).unwrap()),
            v["encrypt_out_hex"].as_str().unwrap()
        );
    }
}

#[test]
fn golden_md5_vectors() {
    use md5::Digest;
    for v in load("vectors.json")["md5"].as_array().unwrap() {
        let mut h = md5::Md5::new();
        h.update(v["input"].as_str().unwrap().as_bytes());
        assert_eq!(
            format!("{:x}", h.finalize()),
            v["digest_hex"].as_str().unwrap()
        );
    }
}

// ---------- disks.json ----------

#[test]
fn golden_disk_lba7_and_lba12() {
    let disks = load("disks.json")["disks"].as_array().unwrap().clone();
    assert!(disks.len() >= 5, "应有 5 套盘数据");
    for d in &disks {
        let name = d["name"].as_str().unwrap();
        let device_id = d["device_id"].as_str().unwrap();

        // LBA7：滚动 XOR 解密 → 明文对照
        let cipher7 = unhex(d["lba7"]["cipher_hex"].as_str().unwrap());
        let k0 = d["lba7"]["k0"].as_u64().unwrap() as u16;
        let plain7 = xor_decode_copy(&cipher7, k0);
        assert_eq!(
            hex::encode(&plain7),
            d["lba7"]["plain_hex"].as_str().unwrap(),
            "{name}: LBA7 解密不符"
        );

        // LBA12：A6B0 解密 → 明文对照
        let cipher12 = unhex(d["lba12"]["cipher_hex"].as_str().unwrap());
        let key = edp_core::crc32::crc_key(device_id);
        let plain12 = a6b0_full(&cipher12, &key, 0);
        assert_eq!(
            hex::encode(&plain12),
            d["lba12"]["plain_hex"].as_str().unwrap(),
            "{name}: LBA12 解密不符"
        );

        // EDPF 条目字段 + file_key 闭环
        for (i, e) in d["entries"].as_array().unwrap().iter().enumerate() {
            let off = i * 0x60;
            let entry = &plain12[off..off + 0x60];
            assert_eq!(&entry[0..4], b"EDPF", "{name} entry{i}: magic");
            assert_eq!(
                u32::from_le_bytes(entry[0x0C..0x10].try_into().unwrap()),
                e["partition_type"].as_u64().unwrap() as u32,
                "{name} entry{i}: partition_type"
            );
            assert_eq!(
                u64::from_le_bytes(entry[0x18..0x20].try_into().unwrap()),
                e["start_sector"].as_u64().unwrap(),
                "{name} entry{i}: start_sector"
            );
            assert_eq!(
                u64::from_le_bytes(entry[0x28..0x30].try_into().unwrap()),
                e["size_bytes"].as_u64().unwrap(),
                "{name} entry{i}: size_bytes"
            );
            if let Some(fk_hex) = e["file_key_hex"].as_str() {
                let sm4 = Sm4Ecb::new(&edp_core::sm4_ecb::wrapping_key());
                let fk = sm4.decrypt_aligned(&entry[0x38..0x48]).unwrap();
                assert_eq!(hex::encode(&fk), fk_hex, "{name} entry{i}: file_key");
                // CRC 闭环
                let kcrc = u32::from_le_bytes(entry[0x34..0x38].try_into().unwrap());
                assert_eq!(crc32_bare(&fk), kcrc, "{name} entry{i}: file_key CRC 闭环");
            }
        }
    }
}

/// disk5 真实盘是 identify 兜底路径的天然回归用例（LBA11 标准参数解不出）。
#[test]
fn golden_disk5_lba11_fails_as_expected() {
    let disks = load("disks.json")["disks"].as_array().unwrap().clone();
    let d5 = disks
        .iter()
        .find(|d| d["name"] == "disk5_real_sandisk")
        .expect("disk5 数据");
    assert_eq!(d5["device_id_source"], "identify_fallback");
    let raw11 = unhex(d5["lba11"]["cipher_hex"].as_str().unwrap());
    let p = &d5["lba11_params"];
    let vid = p["vid"].as_str().unwrap();
    let pid = p["pid"].as_str().unwrap();
    let size = p["size_bytes"].as_u64().unwrap();
    // 标准两候选（真实容量 + CHS 向下取整）都不该解出 PDKB
    let got =
        edp_core::lba11::device_id_from_lba11(raw11.as_slice().try_into().unwrap(), vid, pid, size);
    assert!(
        got.is_none(),
        "disk5 LBA11 标准路径应失败，实际解出 {got:?}"
    );
}

/// disk4 真实盘走 LBA11 标准路径成功。
#[test]
fn golden_disk4_lba11_resolves() {
    let disks = load("disks.json")["disks"].as_array().unwrap().clone();
    let d4 = disks
        .iter()
        .find(|d| d["name"] == "disk4_real_lexar")
        .expect("disk4 数据");
    let raw11 = unhex(d4["lba11"]["cipher_hex"].as_str().unwrap());
    let p = &d4["lba11_params"];
    let got = edp_core::lba11::device_id_from_lba11(
        raw11.as_slice().try_into().unwrap(),
        p["vid"].as_str().unwrap(),
        p["pid"].as_str().unwrap(),
        p["size_bytes"].as_u64().unwrap(),
    );
    assert_eq!(got.as_deref(), Some("disk&ven_lexar&prod_usb_flash_drive"));
}
