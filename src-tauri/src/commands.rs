//! commands.rs — Tauri 命令门面

use crate::{disk, parser, crypto};
use serde::Serialize;

#[tauri::command]
pub fn ping() -> String {
    "edpopen-backend-ready".into()
}

#[tauri::command]
pub fn list_disks() -> Vec<disk::UsbDisk> {
    disk::list_usb_disks()
}

#[derive(Serialize)]
pub struct PartitionRow {
    pub index: u32,
    pub type_name: String,
    pub start: u64,
    pub sectors: u64,
    pub size_gb: String,
}

#[derive(Serialize)]
pub struct LayoutRow {
    pub name: String,      // Boot/Share/Encrypt
    pub start: u64,        // LBA
    pub end: u64,          // LBA(含)
    pub size_gb: String,
    pub note: String,
}

#[derive(Serialize)]
pub struct DiskOverview {
    pub disk: u32,
    pub size_gb: String,
    pub vid: String,
    pub pid: String,
    pub device_id: String,
    pub crc32: String,
    pub lba7_k0: String,
    pub status: parser::DiskStatus,
    pub status_label: String,
    pub lba12_entries: usize,
    pub lba9_eetu: bool,
    pub partitions: Vec<PartitionRow>,
    pub layout: Vec<LayoutRow>,
}

fn status_label(s: parser::DiskStatus) -> String {
    match s {
        parser::DiskStatus::Encrypted => "标准加密盘(未改造)".into(),
        parser::DiskStatus::NoPwd => "免密盘".into(),
        parser::DiskStatus::NotCems => "非 cems 盘".into(),
    }
}

/// 概览: 识别 + 状态判定 + MBR + LBA12 布局
#[tauri::command]
pub fn analyze_disk(disk_no: u32) -> Result<DiskOverview, String> {    if disk_no < 2 { return Err("拒绝系统盘(须 disk2+)".into()); }
    let id = disk::identify(disk_no)
        .ok_or("无法识别 device_id(LBA7 两候选均未解出 EDPF) — 非 cems 盘?")?;

    let raw12 = disk::read_lba(disk_no, 12).map_err(|e| format!("读 LBA12 失败: {e}"))?;
    let crc_key = id.crc.to_le_bytes();
    let dec12 = crypto::a6b0_full(&raw12[..0x170], &crc_key, 0);
    if !dec12.starts_with(b"EDPF") {
        return Err(format!("LBA12 解密后非 EDPF({:02x?}) — device_id 不符或非 cems 盘", &dec12[..4]));
    }
    let entries = parser::parse_edpf(&dec12, 0x60);

    let raw0 = disk::read_lba(disk_no, 0).map_err(|e| format!("读 LBA0 失败: {e}"))?;
    let mbr = parser::parse_mbr(&raw0).unwrap_or_default();

    let raw9 = disk::read_lba(disk_no, 9).map_err(|e| format!("读 LBA9 失败: {e}"))?;
    let lba9_eetu = raw9.iter().any(|&b| b != 0);

    let status = parser::classify(&entries, &mbr, lba9_eetu);

    let usb = disk::list_usb_disks().into_iter().find(|d| d.disk == disk_no);
    let (size_gb, vid, pid) = usb
        .map(|u| (parser::fmt_gb(u.size_bytes), u.vid, u.pid))
        .unwrap_or(("?".into(), "0000".into(), "0000".into()));

    let layout = entries.iter().map(|e| {
        let sectors = e.size / 512;
        LayoutRow {
            name: parser::edpf_type_name(e.ptype),
            start: e.start,
            end: e.start + sectors.saturating_sub(1),
            size_gb: parser::fmt_gb(e.size),
            note: match e.ptype {
                4 => "原样保留不动".into(),
                2 => "明文数据区".into(),
                1 => "启动区".into(),
                _ => String::new(),
            },
        }
    }).collect();

    let partitions = mbr.iter().map(|p| PartitionRow {
        index: p.index,
        type_name: p.type_name.clone(),
        start: p.start,
        sectors: p.sectors,
        size_gb: parser::fmt_gb(p.sectors * 512),
    }).collect();

    Ok(DiskOverview {
        disk: disk_no,
        size_gb,
        vid,
        pid,
        device_id: id.device_id.clone(),
        crc32: format!("{:08X}", id.crc),
        lba7_k0: format!("{:04X}", id.k0),
        lba12_entries: entries.len(),
        status_label: status_label(status),
        status,
        lba9_eetu,
        partitions,
        layout,
    })
}

// ── 扇区读取(raw + 解密 + 字段表) ─────────────────────────────────────────
#[derive(Serialize)]
pub struct SectorView {
    pub disk: u32,
    pub lba: u64,
    pub raw_hex: String,
    pub dec_hex: Option<String>,      // 可解密扇区才有
    pub dec_method: Option<String>,   // 解密方法描述
    pub fields: Vec<parser::FieldRow>,// 字段表(对 dec 视图; LBA0 对 raw)
}

fn hexs(b: &[u8]) -> String { b.iter().map(|x| format!("{x:02x}")).collect() }

#[tauri::command]
pub fn read_sector(disk_no: u32, lba: u64) -> Result<SectorView, String> {
    if disk_no < 2 { return Err("拒绝系统盘".into()); }
    let raw = disk::read_lba(disk_no, lba).map_err(|e| format!("读 LBA{lba} 失败: {e}"))?;
    let mut sv = SectorView { disk: disk_no, lba, raw_hex: hexs(&raw), dec_hex: None, dec_method: None, fields: Vec::new() };

    // 惰性身份识别(仅需要 device_id 的扇区)
    let ident = || disk::identify(disk_no);
    let lba11_params = || -> Option<(Vec<u8>, Vec<u8>, Vec<u64>)> {
        let (vid, pid) = disk::usb_vid_pid(disk_no)?;
        let size = disk::list_usb_disks().into_iter().find(|d| d.disk == disk_no)?.size_bytes;
        let chs = (size / (255 * 63 * 512)) * 255 * 63 * 512;
        Some((vid.into_bytes(), pid.into_bytes(), vec![size, chs]))
    };

    match lba {
        0 => { sv.fields = parser::lba0_fields(&raw); }
        4 => {
            if let Some((dec, serial)) = crypto::lba4_decode(&raw) {
                sv.dec_method = Some(format!("XOR K0=0x{:04X}($$$serial={serial})", crypto::lba4_k0_from_serial(serial)));
                sv.fields = parser::lba4_fields(&dec);
                sv.dec_hex = Some(hexs(&dec));
            }
        }
        6 => {
            let dec = crypto::lba6_decode(&raw);
            let crc = ident().map(|i| i.crc).unwrap_or(0);
            sv.dec_method = Some("XOR K0=0x4DAA(SAFE6)".into());
            sv.fields = parser::lba6_fields(&dec, crc);
            sv.dec_hex = Some(hexs(&dec));
        }
        7 => {
            if let Some(id) = ident() {
                let dec = crypto::xor_rolling(&raw, id.k0);
                if dec.starts_with(b"EDPF") {
                    sv.dec_method = Some(format!("XOR K0=0x{:04X}(CRC32(device_id))", id.k0));
                    sv.fields = parser::lba7_fields(&dec);
                    sv.dec_hex = Some(hexs(&dec));
                }
            }
        }
        8 => {
            if let Some(id) = ident() {
                let mut dec = crypto::a6b0_full(&raw[..0x170], &id.crc.to_le_bytes(), 0);
                dec.extend_from_slice(&[0u8; 144]);
                sv.dec_method = Some("A6B0(368B) key=CRC32(device_id)".into());
                sv.fields = parser::lba8_fields(&dec);
                sv.dec_hex = Some(hexs(&dec));
            }
        }
        9 => {
            if let Some(id) = ident() {
                let mut dec = crypto::a6b0_full(&raw[..0x80], &id.crc.to_le_bytes(), 0);
                dec.extend_from_slice(&[0u8; 128]);
                let xor_part: Vec<u8> = raw[0x100..0x120].iter().map(|b| b ^ 0x88).collect();
                dec.extend_from_slice(&xor_part);
                dec.extend_from_slice(&[0u8; 224]);
                sv.dec_method = Some("A6B0(128B)+XOR0x88(32B)".into());
                sv.fields = parser::lba9_fields(&dec);
                sv.dec_hex = Some(hexs(&dec));
            }
        }
        11 => {
            if let Some((vid, pid, sizes)) = lba11_params() {
                let rand = &raw[..0x100];
                for &sz in &sizes {
                    let mut buf = rand.to_vec();
                    buf.extend_from_slice(&vid);
                    buf.extend_from_slice(&pid);
                    buf.extend_from_slice(&sz.to_le_bytes());
                    let key = crypto::crc32_bare(&buf).to_le_bytes();
                    let pt = crypto::a6b0_full(&raw[0x100..], &key, 0);
                    if pt.starts_with(b"PDKB") {
                        let mut dec = rand.to_vec();
                        dec.extend_from_slice(&pt);
                        let label = if sz % (255 * 63 * 512) == 0 && sz != sizes[0] { "CHS" } else { "DiskSize" };
                        sv.dec_method = Some(format!("A6B0 key=crc32(rand+VID+PID+{label})"));
                        sv.fields = parser::lba11_fields(&dec);
                        sv.dec_hex = Some(hexs(&dec));
                        break;
                    }
                }
            }
        }
        12 => {
            if let Some(id) = ident() {
                let mut dec = crypto::a6b0_full(&raw[..0x170], &id.crc.to_le_bytes(), 0);
                dec.extend_from_slice(&raw[0x170..]);
                if dec.starts_with(b"EDPF") {
                    sv.dec_method = Some("A6B0(368B) key=CRC32(device_id); 尾144B raw".into());
                    sv.fields = parser::lba12_fields(&dec);
                    sv.dec_hex = Some(hexs(&dec));
                }
            }
        }
        _ => {}
    }
    Ok(sv)
}
