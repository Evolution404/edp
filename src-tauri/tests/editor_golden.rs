//! editor_golden.rs — 编辑器“解密视图不修改 → 重加密”必须逐字节还原真实盘 raw。

use edpopen_lib::{crypto, disk, editor};

mod support;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
        .collect()
}

fn editor_view(lba: u64, raw: &[u8], id: &disk::Identity, lba11_key: Option<&[u8]>) -> Vec<u8> {
    match lba {
        4 => crypto::lba4_decode(raw).unwrap().0,
        6 => crypto::lba6_decode(raw),
        7 => crypto::xor_rolling(raw, id.k0),
        8 => {
            let mut dec = crypto::a6b0_full(&raw[..0x170], &id.crc.to_le_bytes(), 0);
            dec.extend_from_slice(&raw[0x170..]);
            dec
        }
        9 => {
            if raw.iter().all(|&b| b == 0) {
                raw.to_vec()
            } else {
                let mut dec = crypto::a6b0_full(&raw[..0x80], &id.crc.to_le_bytes(), 0);
                dec.extend_from_slice(&raw[0x80..0x100]);
                dec.extend(raw[0x100..0x120].iter().map(|b| b ^ 0x88));
                dec.extend_from_slice(&raw[0x120..]);
                dec
            }
        }
        11 => {
            let key = lba11_key.expect("LBA11 key");
            let mut dec = raw[..0x100].to_vec();
            dec.extend_from_slice(&crypto::a6b0_full(&raw[0x100..], key, 0));
            dec
        }
        12 => {
            let mut dec = crypto::a6b0_full(&raw[..0x170], &id.crc.to_le_bytes(), 0);
            dec.extend_from_slice(&raw[0x170..]);
            dec
        }
        _ => raw.to_vec(),
    }
}

#[test]
fn unchanged_editor_view_reencrypts_to_exact_raw() {
    let Some(v) = support::load_json("vectors.json") else { return; };
    for d in v["disks"].as_array().unwrap() {
        let name = d["name"].as_str().unwrap();
        let device_id = d["device_id"].as_str().unwrap().to_string();
        let crc = crypto::crc32_bare(device_id.as_bytes());
        let id = disk::Identity { device_id, crc, k0: disk::lba7_k0(crc) };
        let size_bytes = d["size_bytes"].as_u64().unwrap();
        let ctx = editor::EditContext {
            identity: &id,
            vid: d["vid"].as_str().unwrap(),
            pid: d["pid"].as_str().unwrap(),
            size_bytes,
        };

        for lba in [4u64, 6, 7, 8, 9, 11, 12] {
            let raw = unhex(d["sectors"][lba.to_string()]["raw_hex"].as_str().unwrap());
            let lba11_key = d["lba11_key"].as_str().map(unhex);
            if lba == 11 && lba11_key.is_none() { continue; }
            let view = editor_view(lba, &raw, &id, lba11_key.as_deref());
            let got = editor::reencrypt_sector(lba, &raw, &view, &ctx)
                .unwrap_or_else(|e| panic!("{name} LBA{lba}: {e}"));
            assert_eq!(got, raw, "{name} LBA{lba} unchanged view must reproduce raw");
        }
    }
}

#[test]
fn one_byte_edit_survives_reencrypt_and_decrypt() {
    let Some(v) = support::load_json("vectors.json") else { return; };
    for d in v["disks"].as_array().unwrap() {
        let name = d["name"].as_str().unwrap();
        let device_id = d["device_id"].as_str().unwrap().to_string();
        let crc = crypto::crc32_bare(device_id.as_bytes());
        let id = disk::Identity { device_id, crc, k0: disk::lba7_k0(crc) };
        let ctx = editor::EditContext {
            identity: &id,
            vid: d["vid"].as_str().unwrap(),
            pid: d["pid"].as_str().unwrap(),
            size_bytes: d["size_bytes"].as_u64().unwrap(),
        };
        let lba11_key = d["lba11_key"].as_str().map(unhex);

        for (lba, off) in [(4u64, 0x40usize), (6, 0x20), (7, 0x30), (8, 0x20), (9, 0x10), (11, 0x110), (12, 0x20)] {
            if lba == 11 && lba11_key.is_none() { continue; }
            let raw = unhex(d["sectors"][lba.to_string()]["raw_hex"].as_str().unwrap());
            let mut edited = editor_view(lba, &raw, &id, lba11_key.as_deref());
            edited[off] ^= 0x5a;
            let encoded = editor::reencrypt_sector(lba, &raw, &edited, &ctx)
                .unwrap_or_else(|e| panic!("{name} LBA{lba}: {e}"));
            let decoded = editor_view(lba, &encoded, &id, lba11_key.as_deref());
            if lba == 6 {
                assert_eq!(&decoded[..0x1FC], &edited[..0x1FC], "{name} LBA6 edited payload");
                assert_eq!(u32::from_le_bytes(encoded[0x1FC..].try_into().unwrap()), crypto::lba6_checksum(&encoded[..0x1FC]));
            } else {
                assert_eq!(decoded, edited, "{name} LBA{lba} edited view roundtrip");
            }
        }
    }
}
