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
pub fn analyze_disk(disk_no: u32) -> Result<DiskOverview, String> {
    if disk_no < 2 { return Err("拒绝系统盘(须 disk2+)".into()); }
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
