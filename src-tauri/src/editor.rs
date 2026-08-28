//! editor.rs — 字节编辑器的加密感知重编码核心。
//! 输入始终是用户看到的 512B 编辑视图；输出是可写回盘的 512B raw。

use crate::{crypto, disk};

const SECTOR: usize = 512;
const EDPF_ENC_LEN: usize = 0x170;

#[derive(Debug, Clone, serde::Serialize)]
pub struct EditPreview {
    pub lba: u64,
    pub raw_hex: String,
    pub changed_raw_offsets: Vec<usize>,
    pub warnings: Vec<String>,
    pub save_blocked_reason: Option<String>,
}

pub struct EditContext<'a> {
    pub identity: &'a disk::Identity,
    pub vid: &'a str,
    pub pid: &'a str,
    pub size_bytes: u64,
}

fn lba11_key(rand: &[u8], vid: &str, pid: &str, size: u64) -> [u8; 4] {
    let mut seed = rand.to_vec();
    seed.extend_from_slice(vid.as_bytes());
    seed.extend_from_slice(pid.as_bytes());
    seed.extend_from_slice(&size.to_le_bytes());
    crypto::crc32_bare(&seed).to_le_bytes()
}

fn lba11_size_mode(raw: &[u8], ctx: &EditContext<'_>) -> Option<u64> {
    if raw.len() != SECTOR { return None; }
    let unit = 255u64 * 63 * SECTOR as u64;
    let chs = (ctx.size_bytes / unit) * unit;
    let mut sizes = vec![ctx.size_bytes];
    if chs != 0 && chs != ctx.size_bytes { sizes.push(chs); }
    for size in sizes {
        let key = lba11_key(&raw[..0x100], ctx.vid, ctx.pid, size);
        let dec = crypto::a6b0_full(&raw[0x100..], &key, 0);
        if dec.starts_with(b"PDKB") { return Some(size); }
    }
    None
}

fn lba4_encode(original_raw: &[u8], edited: &[u8]) -> Result<Vec<u8>, String> {
    let original_serial = crypto::lba4_parse_serial(original_raw).ok_or("原 LBA4 无法解析 labelOnlyId")?;
    let new_serial = crypto::lba4_parse_serial(edited).ok_or("编辑后 LBA4 头部缺少合法 $$$<labelOnlyId>$$$")?;
    let k0 = crypto::lba4_k0_from_serial(new_serial);
    let plain = &edited[0x18..0x200];
    let mut cipher = crypto::xor_rolling(plain, k0);
    for i in 0..plain.len() {
        if original_raw[0x18 + i] == 0 && plain[i] == 0 {
            cipher[i] = 0;
        }
    }
    let mut out = edited[..0x18].to_vec();
    out.extend_from_slice(&cipher);
    if original_serial != new_serial && crypto::lba4_parse_serial(&out) != Some(new_serial) {
        return Err("LBA4 新 labelOnlyId 头部自检失败".into());
    }
    Ok(out)
}

pub fn reencrypt_sector(
    lba: u64,
    original_raw: &[u8],
    edited_view: &[u8],
    ctx: &EditContext<'_>,
) -> Result<Vec<u8>, String> {
    if original_raw.len() != SECTOR || edited_view.len() != SECTOR {
        return Err("扇区必须恰好 512B".into());
    }
    let crc_key = ctx.identity.crc.to_le_bytes();
    match lba {
        0 => Ok(edited_view.to_vec()),
        4 => lba4_encode(original_raw, edited_view),
        6 => {
            let cipher = crypto::xor_rolling(&edited_view[..0x1FC], crypto::LBA6_K0);
            let checksum = crypto::lba6_checksum(&cipher);
            let mut out = cipher;
            out.extend_from_slice(&checksum.to_le_bytes());
            Ok(out)
        }
        7 => Ok(crypto::xor_rolling(edited_view, ctx.identity.k0)),
        8 => {
            let mut out = crypto::a7f0_full(&edited_view[..EDPF_ENC_LEN], &crc_key, 0);
            out.extend_from_slice(&edited_view[EDPF_ENC_LEN..]);
            Ok(out)
        }
        9 => {
            if original_raw.iter().all(|&b| b == 0) && edited_view.iter().all(|&b| b == 0) {
                return Ok(vec![0u8; SECTOR]);
            }
            let mut out = crypto::a7f0_full(&edited_view[..0x80], &crc_key, 0);
            out.extend_from_slice(&edited_view[0x80..0x100]);
            out.extend(edited_view[0x100..0x120].iter().map(|b| b ^ 0x88));
            out.extend_from_slice(&edited_view[0x120..]);
            Ok(out)
        }
        11 => {
            let size_mode = lba11_size_mode(original_raw, ctx)
                .ok_or("原 LBA11 无法确定 DiskSize/CHS 加密口径")?;
            let key = lba11_key(&edited_view[..0x100], ctx.vid, ctx.pid, size_mode);
            let mut out = edited_view[..0x100].to_vec();
            out.extend_from_slice(&crypto::a7f0_full(&edited_view[0x100..], &key, 0));
            Ok(out)
        }
        12 => {
            let mut out = crypto::a7f0_full(&edited_view[..EDPF_ENC_LEN], &crc_key, 0);
            out.extend_from_slice(&edited_view[EDPF_ENC_LEN..]);
            Ok(out)
        }
        _ => Ok(edited_view.to_vec()),
    }
}

pub fn warnings_for_edit(lba: u64, original_view: &[u8], edited: &[u8]) -> Vec<String> {
    if original_view.len() != SECTOR || edited.len() != SECTOR { return vec!["扇区长度异常".into()]; }
    let changed = |a: usize, b: usize| original_view[a..b] != edited[a..b];
    let mut w = Vec::new();
    match lba {
        4 if changed(0, 0x18) => w.push("LBA4 头部变化可能改变 labelOnlyId 与滚动 XOR key；当前安全保存禁止改变 labelOnlyId".into()),
        6 if changed(0x1FC, 0x200) => w.push("LBA6 末尾校验和由程序自动重算，手工修改值不会直接写入".into()),
        7 if changed(0xC0, 0xC8) => w.push("LBA7 表尾终止符属于敏感区，修改可能触发客户端结构异常".into()),
        11 if changed(0, 0x100) => w.push("LBA11 rand 区变化会同时改变后半区 A6B0 key".into()),
        12 => {
            if changed(0x120, 0x128) { w.push("LBA12 EDPF 表尾终止符属于敏感区".into()); }
            if changed(0x170, 0x200) { w.push("LBA12 尾 144B 为 raw 敏感区，将按编辑值直接写入".into()); }
        }
        _ => {}
    }
    w
}

pub fn preview(
    lba: u64,
    original_raw: &[u8],
    original_view: &[u8],
    edited_view: &[u8],
    ctx: &EditContext<'_>,
) -> Result<EditPreview, String> {
    let raw = reencrypt_sector(lba, original_raw, edited_view, ctx)?;
    let changed_raw_offsets = raw.iter().zip(original_raw).enumerate()
        .filter_map(|(i, (a, b))| (a != b).then_some(i))
        .collect();
    let save_blocked_reason = if lba == 4 {
        let old_serial = crypto::lba4_parse_serial(original_view);
        let new_serial = crypto::lba4_parse_serial(edited_view);
        if old_serial != new_serial {
            Some("禁止保存会改变 LBA4 labelOnlyId 的编辑；该值是同型号多盘恢复时的唯一身份依据".into())
        } else {
            None
        }
    } else {
        None
    };
    Ok(EditPreview {
        lba,
        raw_hex: raw.iter().map(|b| format!("{b:02x}")).collect(),
        changed_raw_offsets,
        warnings: warnings_for_edit(lba, original_view, edited_view),
        save_blocked_reason,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lba6_reencrypt_recalculates_checksum() {
        let id = disk::Identity { device_id: "x".into(), crc: 1, k0: 2 };
        let ctx = EditContext { identity: &id, vid: "0000", pid: "0000", size_bytes: 1 };
        let original = vec![0u8; 512];
        let mut edited = vec![0u8; 512];
        edited[12] = 0x5a;
        edited[0x1FC..].fill(0xff);
        let raw = reencrypt_sector(6, &original, &edited, &ctx).unwrap();
        assert_eq!(u32::from_le_bytes(raw[0x1FC..].try_into().unwrap()), crypto::lba6_checksum(&raw[..0x1FC]));
        assert_eq!(crypto::lba6_decode(&raw)[12], 0x5a);
    }

    #[test]
    fn lba4_label_id_change_is_previewable_but_save_blocked() {
        let id = disk::Identity { device_id: "x".into(), crc: 1, k0: 2 };
        let ctx = EditContext { identity: &id, vid: "0000", pid: "0000", size_bytes: 1 };
        let mut raw = vec![0u8; 512];
        raw[..9].copy_from_slice(b"$$$123$$$");
        let original_view = crypto::lba4_decode(&raw).unwrap().0;
        let mut edited = original_view.clone();
        edited[..9].copy_from_slice(b"$$$124$$$");
        let p = preview(4, &raw, &original_view, &edited, &ctx).unwrap();
        assert!(p.save_blocked_reason.is_some());
        assert!(!p.changed_raw_offsets.is_empty());
    }

    #[test]
    fn raw_lbas_roundtrip_directly() {
        let id = disk::Identity { device_id: "x".into(), crc: 1, k0: 2 };
        let ctx = EditContext { identity: &id, vid: "0000", pid: "0000", size_bytes: 1 };
        let original = vec![0u8; 512];
        let mut edited = original.clone();
        edited[1] = 7;
        assert_eq!(reencrypt_sector(0, &original, &edited, &ctx).unwrap(), edited);
        assert_eq!(reencrypt_sector(13, &original, &edited, &ctx).unwrap(), edited);
    }
}
