//! sector.rs — raw 512B sector → 解密视图 + 结构化字段。
//! 纯算法层，不进行磁盘枚举或 I/O。

use serde::Serialize;

use crate::{crypto, parser, Identity};

pub const SECTOR_SIZE: usize = 512;

pub struct SectorDecodeContext<'a> {
    pub identity: Option<&'a Identity>,
    pub vid: Option<&'a str>,
    pub pid: Option<&'a str>,
    pub size_bytes: Option<u64>,
}

impl<'a> SectorDecodeContext<'a> {
    pub fn empty() -> Self {
        Self { identity: None, vid: None, pid: None, size_bytes: None }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SectorDecoded {
    pub lba: u64,
    pub decoded: Option<Vec<u8>>,
    pub method: Option<String>,
    pub fields: Vec<parser::FieldRow>,
}

fn lba11_decode(raw: &[u8], vid: &str, pid: &str, size: u64) -> Option<(Vec<u8>, &'static str)> {
    let rand = &raw[..0x100];
    let chs = (size / (255 * 63 * 512)) * 255 * 63 * 512;
    let sizes = if chs != 0 && chs != size { vec![(size, "DiskSize"), (chs, "CHS")] } else { vec![(size, "DiskSize")] };
    for (sz, label) in sizes {
        let mut seed = rand.to_vec();
        seed.extend_from_slice(vid.as_bytes());
        seed.extend_from_slice(pid.as_bytes());
        seed.extend_from_slice(&sz.to_le_bytes());
        let key = crypto::crc32_bare(&seed).to_le_bytes();
        let pt = crypto::a6b0_full(&raw[0x100..], &key, 0);
        if pt.starts_with(b"PDKB") {
            let mut dec = rand.to_vec();
            dec.extend_from_slice(&pt);
            return Some((dec, label));
        }
    }
    None
}

pub fn decode_sector(
    lba: u64,
    raw: &[u8],
    ctx: &SectorDecodeContext<'_>,
) -> Result<SectorDecoded, String> {
    if raw.len() != SECTOR_SIZE {
        return Err(format!("扇区必须恰好 {SECTOR_SIZE}B"));
    }

    let mut out = SectorDecoded { lba, decoded: None, method: None, fields: Vec::new() };
    match lba {
        0 => {
            out.fields = parser::lba0_fields(raw);
        }
        4 => {
            if let Some((dec, serial)) = crypto::lba4_decode(raw) {
                out.method = Some(format!("XOR K0=0x{:04X}($$$serial={serial})", crypto::lba4_k0_from_serial(serial)));
                out.fields = parser::lba4_fields(&dec);
                out.decoded = Some(dec);
            }
        }
        6 => {
            let dec = crypto::lba6_decode(raw);
            let crc = ctx.identity.map(|i| i.crc).unwrap_or(0);
            out.method = Some("XOR K0=0x4DAA(SAFE6)".into());
            out.fields = parser::lba6_fields(&dec, crc);
            out.decoded = Some(dec);
        }
        7 => {
            if let Some(id) = ctx.identity {
                let dec = crypto::xor_rolling(raw, id.k0);
                if dec.starts_with(b"EDPF") {
                    out.method = Some(format!("XOR K0=0x{:04X}(CRC32(device_id))", id.k0));
                    out.fields = parser::lba7_fields(&dec);
                    out.decoded = Some(dec);
                }
            }
        }
        8 => {
            if let Some(id) = ctx.identity {
                let mut dec = crypto::a6b0_full(&raw[..0x170], &id.crc.to_le_bytes(), 0);
                dec.extend_from_slice(&raw[0x170..]);
                out.method = Some("A6B0(368B) key=CRC32(device_id); 尾144B raw".into());
                out.fields = parser::lba8_fields(&dec);
                out.decoded = Some(dec);
            }
        }
        9 => {
            if raw.iter().all(|&b| b == 0) {
                out.method = Some("全零扇区(raw)".into());
                out.fields = parser::lba9_fields(raw);
                out.decoded = Some(raw.to_vec());
            } else if let Some(id) = ctx.identity {
                let mut dec = crypto::a6b0_full(&raw[..0x80], &id.crc.to_le_bytes(), 0);
                dec.extend_from_slice(&raw[0x80..0x100]);
                dec.extend(raw[0x100..0x120].iter().map(|b| b ^ 0x88));
                dec.extend_from_slice(&raw[0x120..]);
                out.method = Some("A6B0(128B)+raw(128B)+XOR0x88(32B)+raw(224B)".into());
                out.fields = parser::lba9_fields(&dec);
                out.decoded = Some(dec);
            }
        }
        11 => {
            if let (Some(vid), Some(pid), Some(size)) = (ctx.vid, ctx.pid, ctx.size_bytes) {
                if let Some((dec, label)) = lba11_decode(raw, vid, pid, size) {
                    out.method = Some(format!("A6B0 key=crc32(rand+VID+PID+{label})"));
                    out.fields = parser::lba11_fields(&dec);
                    out.decoded = Some(dec);
                }
            }
        }
        12 => {
            if let Some(id) = ctx.identity {
                let mut dec = crypto::a6b0_full(&raw[..0x170], &id.crc.to_le_bytes(), 0);
                dec.extend_from_slice(&raw[0x170..]);
                if dec.starts_with(b"EDPF") {
                    out.method = Some("A6B0(368B) key=CRC32(device_id); 尾144B raw".into());
                    out.fields = parser::lba12_fields(&dec);
                    out.decoded = Some(dec);
                }
            }
        }
        _ => {}
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_lba0_returns_fields_without_decoded_copy() {
        let mut raw = vec![0u8; 512];
        raw[0x1FE] = 0x55;
        raw[0x1FF] = 0xAA;
        let d = decode_sector(0, &raw, &SectorDecodeContext::empty()).unwrap();
        assert!(d.decoded.is_none());
        assert!(d.fields.iter().any(|f| f.name == "55AA"));
    }

    #[test]
    fn zero_lba9_is_identity_view() {
        let raw = vec![0u8; 512];
        let d = decode_sector(9, &raw, &SectorDecodeContext::empty()).unwrap();
        assert_eq!(d.decoded.as_deref(), Some(raw.as_slice()));
        assert_eq!(d.method.as_deref(), Some("全零扇区(raw)"));
    }
}
