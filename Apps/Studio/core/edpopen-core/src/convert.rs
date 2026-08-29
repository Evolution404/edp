//! convert.rs — EDP 免密改造的纯算法核心。
//! 不执行任何磁盘 I/O；输入 5 个 raw sector，输出改造计划。

use crate::crypto;

pub const PWD_CRC: u32 = 0x0429735D;
pub const NOPWD_LBA6_1CA: u32 = 128_480;
pub const E7: usize = 0x40;
pub const E12: usize = 0x60;
const EDPF_ENC_LEN: usize = 368;

#[derive(Debug)]
pub struct ConvertPlan {
    pub share: u64,
    pub enc_start: u64,
    pub enc_size: u64,
    pub lba0: Vec<u8>,
    pub lba6: Vec<u8>,
    pub lba7: Vec<u8>,
    pub lba12: Vec<u8>,
    pub lba9: Option<Vec<u8>>,
}

fn u32le(d: &mut [u8], off: usize, v: u32) { d[off..off + 4].copy_from_slice(&v.to_le_bytes()); }
fn u64le(d: &mut [u8], off: usize, v: u64) { d[off..off + 8].copy_from_slice(&v.to_le_bytes()); }

fn make_entry(src_e: &[u8], ptype: u32, start: u64, size: u64) -> Vec<u8> {
    let mut e = src_e.to_vec();
    e[..4].copy_from_slice(b"EDPF");
    u32le(&mut e, 0x08, 2);
    u32le(&mut e, 0x0C, ptype);
    u32le(&mut e, 0x10, 1);
    u32le(&mut e, 0x14, 1);
    u64le(&mut e, 0x18, start);
    u64le(&mut e, 0x20, 0x200);
    u64le(&mut e, 0x28, size);
    u32le(&mut e, 0x30, PWD_CRC);
    e
}

fn find_type_entry(dec: &[u8], stride: usize, ptype: u32) -> Option<usize> {
    (0..3).find(|&i| {
        let e = &dec[i * stride..];
        &e[..4] == b"EDPF" && u32::from_le_bytes(e[0x0C..0x10].try_into().unwrap()) == ptype
    })
}

fn convert_lba0(raw: &[u8], share: u64) -> Vec<u8> {
    let mut out = raw.to_vec();
    for i in 0..4 { out[0x1BE + i * 16..0x1BE + (i + 1) * 16].fill(0); }
    out[0x1BE + 4] = 0x07;
    out[0x1BE + 8..0x1BE + 12].copy_from_slice(&63u32.to_le_bytes());
    out[0x1BE + 12..0x1BE + 16].copy_from_slice(&(share as u32).to_le_bytes());
    out[0x1FE..0x200].copy_from_slice(b"\x55\xaa");
    out
}

fn convert_lba6(raw: &[u8]) -> Result<Vec<u8>, String> {
    let mut dec = crypto::lba6_decode(raw);
    if dec[0x188..0x190] == [0; 8] {
        return Err("LBA6 解密后 0x188 magic 为零 — 非法 SAFE6".into());
    }
    u32le(&mut dec, 0x1CA, NOPWD_LBA6_1CA);
    dec[0x1D4..0x1ED].fill(0);
    let cipher = crypto::xor_rolling(&dec[..0x1FC], crypto::LBA6_K0);
    let csum = crypto::lba6_checksum(&cipher);
    let mut out = cipher;
    out.extend_from_slice(&csum.to_le_bytes());
    if crypto::lba6_decode(&out)[..0x1FC] != dec[..0x1FC] {
        return Err("LBA6 往返自检失败".into());
    }
    Ok(out)
}

fn convert_lba7(raw: &[u8], k0: u16, share: u64) -> Result<Vec<u8>, String> {
    let mut dec = crypto::xor_rolling(raw, k0);
    if !dec.starts_with(b"EDPF") {
        return Err("LBA7 解密后非 EDPF — device_id/K0 不符".into());
    }
    let src = dec[find_type_entry(&dec, E7, 4).ok_or("LBA7 无 type=4 entry")? * E7..][..E7].to_vec();
    dec[..E7].copy_from_slice(&make_entry(&src, 2, 63, share * 512));
    let (s1, z1) = {
        let e1 = &dec[find_type_entry(&dec, E7, 4).ok_or("LBA7 type=4 消失")? * E7..];
        let s = u64::from_le_bytes(e1[0x18..0x20].try_into().unwrap());
        let z = u64::from_le_bytes(e1[0x28..0x30].try_into().unwrap());
        (s, z)
    };
    dec[E7..2 * E7].copy_from_slice(&make_entry(&src, 4, s1, z1));
    dec[2 * E7..3 * E7].fill(0);
    Ok(crypto::xor_rolling(&dec, k0))
}

fn convert_lba12(raw: &[u8], crc_key: &[u8; 4], share: u64) -> Result<Vec<u8>, String> {
    let mut dec = crypto::a6b0_full(&raw[..EDPF_ENC_LEN], crc_key, 0);
    if !dec.starts_with(b"EDPF") {
        return Err("LBA12 解密后非 EDPF".into());
    }
    let src = dec[find_type_entry(&dec, E12, 4).ok_or("LBA12 无 type=4 entry")? * E12..][..E12].to_vec();
    dec[..E12].copy_from_slice(&make_entry(&src, 2, 63, share * 512));
    let (s1, z1) = {
        let s = u64::from_le_bytes(src[0x18..0x20].try_into().unwrap());
        let z = u64::from_le_bytes(src[0x28..0x30].try_into().unwrap());
        (s, z)
    };
    dec[E12..2 * E12].copy_from_slice(&make_entry(&src, 4, s1, z1));
    dec[2 * E12..3 * E12].fill(0);
    let mut out = crypto::a7f0_full(&dec, crc_key, 0);
    out.extend_from_slice(&raw[EDPF_ENC_LEN..]);
    if crypto::a6b0_full(&out[..EDPF_ENC_LEN], crc_key, 0) != dec {
        return Err("LBA12 往返自检失败".into());
    }
    Ok(out)
}

/// 5 扇改造。`size_gb=None` 时 Share 默认延伸到 Encrypt 起点前。
pub fn convert(
    raw0: &[u8], raw6: &[u8], raw7: &[u8], raw9: &[u8], raw12: &[u8],
    crc: u32, k0: u16, size_gb: Option<f64>,
) -> Result<ConvertPlan, String> {
    let crc_key = crc.to_le_bytes();
    let dec12 = crypto::a6b0_full(&raw12[..EDPF_ENC_LEN], &crc_key, 0);
    if !dec12.starts_with(b"EDPF") { return Err("LBA12 非 EDPF — 非可转换盘".into()); }
    let enc_idx = find_type_entry(&dec12, E12, 4).ok_or("LBA12 无 Encrypt entry")?;
    let enc_e = &dec12[enc_idx * E12..];
    let enc_start = u64::from_le_bytes(enc_e[0x18..0x20].try_into().unwrap());
    let enc_size = u64::from_le_bytes(enc_e[0x28..0x30].try_into().unwrap());
    let share = match size_gb {
        Some(gb) => ((gb * 1e9 / 512.0).round() as u64 / 8) * 8,
        None => enc_start - 63,
    };
    if 63 + share > enc_start {
        return Err(format!("Share@63+{share} 越过 Encrypt@{enc_start}"));
    }
    Ok(ConvertPlan {
        share, enc_start, enc_size,
        lba0: convert_lba0(raw0, share),
        lba6: convert_lba6(raw6)?,
        lba7: convert_lba7(raw7, k0, share)?,
        lba12: convert_lba12(raw12, &crc_key, share)?,
        lba9: if raw9.iter().any(|&b| b != 0) { Some(vec![0u8; 512]) } else { None },
    })
}
