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
    let id = disk::identify_checked(disk_no)?;

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

// ── 盘地图(全盘区域 + LBA0-13 方格) ───────────────────────────────────────
#[derive(Serialize)]
pub struct RegionRow {
    pub name: String,
    pub start_lba: u64,
    pub end_lba: u64,        // 含
    pub size_gb: String,
    pub color: String,       // meta/data/encrypt/free/tail/zero
    pub desc: String,
}

#[derive(Serialize)]
pub struct MetaCell {
    pub lba: u64,
    pub name: String,
    pub color: String,
    pub desc: String,        // hover 释义(含义+加密方法+关键值)
}

#[derive(Serialize)]
pub struct DiskMap {
    pub disk: u32,
    pub total_sectors: u64,
    pub size_gb: String,
    pub regions: Vec<RegionRow>,
    pub meta: Vec<MetaCell>,
    pub tail: Vec<RegionRow>,
}

#[tauri::command]
pub fn disk_map(disk_no: u32) -> Result<DiskMap, String> {
    let usb = disk::list_usb_disks().into_iter().find(|d| d.disk == disk_no)
        .ok_or("未找到该 USB 盘")?;
    let total = usb.size_bytes / 512;
    let chs_base = total / 16065 * 16065;

    // LBA12 布局
    let raw12 = disk::read_lba(disk_no, 12).map_err(|e| format!("读 LBA12: {e}"))?;
    let mut entries = Vec::new();
    if let Some(id) = disk::identify(disk_no) {
        let dec = crypto::a6b0_full(&raw12[..0x170], &id.crc.to_le_bytes(), 0);
        if dec.starts_with(b"EDPF") { entries = parser::parse_edpf(&dec, 0x60); }
    }
    let mut regions = Vec::new();
    regions.push(RegionRow { name: "元数据区".into(), start_lba: 0, end_lba: 62,
        size_gb: parser::fmt_gb(63 * 512), color: "meta".into(),
        desc: "LBA0-13 cems 元数据(MBR/标签/EDPF/密钥), 其后保留".into() });
    for e in &entries {
        if e.ptype == 4 && e.size == 3072 { continue; }   // LBA12 的 IIR 指针不是分区
        let sectors = e.size / 512;
        regions.push(RegionRow {
            name: parser::edpf_type_name(e.ptype),
            start_lba: e.start, end_lba: e.start + sectors.saturating_sub(1),
            size_gb: parser::fmt_gb(e.size),
            color: if e.ptype == 2 { "data".into() } else { "boot".into() },
            desc: match e.ptype {
                2 => "Share 明文数据区(MBR 直挂, 免密读写)".into(),
                1 => "Boot 启动区(FAT16, 加密盘形态)".into(),
                _ => String::new(),
            },
        });
    }
    // 尾部区域(CHS 基准, capture_disk 口径)
    let tail_def: &[(&str, u64, u64, &str)] = &[
        ("Region A", 1792, 6, "IIR 密钥表区(LBA7 type4 指针指向; 免密盘全零)"),
        ("IIR", 512, 4, "IIR 基准区(GetFlagInfo 读, 全零则 labelValidate 短路)"),
        ("TagExp", 480, 8, "标签过期区(只读)"),
        ("loginCfg", 416, 14, "登录策略 JSON 配置区"),
        ("USB签名", 384, 4, "USB 签名区"),
    ];
    let mut tail = Vec::new();
    for (name, back, nsec, desc) in tail_def {
        let start = chs_base - back;
        tail.push(RegionRow { name: name.to_string(), start_lba: start, end_lba: start + nsec - 1,
            size_gb: format!("{nsec} 扇"), color: "tail".into(), desc: desc.to_string() });
    }
    // 空档 = 最后分区结束 → Region A
    let last_part_end = regions.iter().filter(|r| r.color != "meta").map(|r| r.end_lba).max().unwrap_or(62);
    if last_part_end + 1 < chs_base - 1792 {
        regions.push(RegionRow { name: "空档".into(), start_lba: last_part_end + 1, end_lba: chs_base - 1793,
            size_gb: parser::fmt_gb((chs_base - 1792 - last_part_end - 1) * 512), color: "free".into(),
            desc: "未定义区域".into() });
    }

    // LBA0-13 方格
    let mut meta = Vec::new();
    for lba in 0u64..14 {
        let (name, color, desc) = match lba {
            0 => ("MBR", "part", "主引导记录: 分区表(Share 直挂=免密 / Boot 小分区=加密)"),
            4 => ("标签索引", "key", "$$$labelOnlyId$$$ + 三件套(xor8/2Nd), 盘唯一标识"),
            6 => ("SAFE6", "label", "盘标签: 部门/用户/CRC32(device_id)/校验和"),
            7 => ("EDPF·旧", "part", "分区表(64B entry): Share + Encrypt(IIR 指针 3072B); K0 滚动XOR"),
            8 => ("LLGB", "label", "ELABEL 标签键值(Dept/User/GLAB…); A6B0 加密"),
            9 => ("EETU", "cipher", "临时使用区; 全零=无(免密特征)"),
            11 => ("PDKB", "key", "device_id 备份块: 解 LBA7/8/12 的 key 源"),
            12 => ("EDPF·新", "part", "分区表(96B entry): Share/Encrypt + salt/algo; A6B0 加密"),
            _ => ("保留", "zero", "全零保留区"),
        };
        meta.push(MetaCell { lba, name: name.into(), color: color.into(), desc: desc.into() });
    }

    Ok(DiskMap { disk: disk_no, total_sectors: total, size_gb: parser::fmt_gb(usb.size_bytes),
        regions, meta, tail })
}

// ── 免密改造: 预览 + 提权写入 ────────────────────────────────────────────
use crate::convert;

#[derive(Serialize)]
pub struct ConvertPreview {
    pub status: parser::DiskStatus,
    pub status_label: String,
    pub convertible: bool,
    pub reason: String,                // 不可转换原因
    pub share: u64,
    pub share_gb: String,
    pub enc_start: u64,
    pub enc_size_gb: String,
    pub sectors: Vec<u32>,             // 将写入的 LBA 列表
    pub lba9_write: bool,
    pub device_id: String,
}

fn build_plan(disk_no: u32, size_gb: Option<f64>) -> Result<(disk::Identity, convert::ConvertPlan, parser::DiskStatus), String> {
    let id = disk::identify_checked(disk_no)?;
    let raw = |lba: u64| disk::read_lba(disk_no, lba).map_err(|e| format!("读 LBA{lba}: {e}"));
    let raw12 = raw(12)?;
    let dec12 = crypto::a6b0_full(&raw12[..0x170], &id.crc.to_le_bytes(), 0);
    if !dec12.starts_with(b"EDPF") { return Err("LBA12 非 EDPF — 非可转换盘".into()); }
    let entries = parser::parse_edpf(&dec12, 0x60);
    let raw0 = raw(0)?;
    let mbr = parser::parse_mbr(&raw0).unwrap_or_default();
    let raw9 = raw(9)?;
    let status = parser::classify(&entries, &mbr, raw9.iter().any(|&b| b != 0));
    let plan = convert::convert(&raw0, &raw(6)?, &raw(7)?, &raw9, &raw12, id.crc, id.k0, size_gb)?;
    Ok((id, plan, status))
}

#[tauri::command]
pub fn convert_preview(disk_no: u32, size_gb: Option<f64>) -> Result<ConvertPreview, String> {
    let (id, plan, status) = build_plan(disk_no, size_gb)?;
    let (convertible, reason) = match status {
        parser::DiskStatus::Encrypted => (true, String::new()),
        parser::DiskStatus::NoPwd => (false, "该盘已是免密盘, 拒绝重复改造".into()),
        parser::DiskStatus::NotCems => (false, "非 cems 盘或结构异常".into()),
    };
    let mut sectors: Vec<u32> = vec![0, 6, 7, 12];
    if plan.lba9.is_some() { sectors.push(9); }
    Ok(ConvertPreview {
        status, status_label: status_label_id(status),
        convertible, reason,
        share: plan.share,
        share_gb: parser::fmt_gb(plan.share * 512),
        enc_start: plan.enc_start,
        enc_size_gb: parser::fmt_gb(plan.enc_size),
        sectors, lba9_write: plan.lba9.is_some(),
        device_id: id.device_id,
    })
}

fn status_label_id(s: parser::DiskStatus) -> String {
    status_label(s)
}

#[derive(Serialize, serde::Deserialize)]
pub struct ApplyResult {
    pub ok: bool,
    pub backup_path: Option<String>,
    pub written: Vec<u64>,
    pub verified: Vec<u64>,
    pub error: Option<String>,
}

/// 正式写入：再次构造并锁定目标身份 → 卸载 → authopen O_RDWR → 备份 → 写入 → 同 FD 回读校验。
#[tauri::command]
pub fn apply_convert(disk_no: u32, size_gb: Option<f64>) -> Result<ApplyResult, String> {
    let (id, plan, status) = build_plan(disk_no, size_gb)?;
    match status {
        parser::DiskStatus::Encrypted => {}
        parser::DiskStatus::NoPwd => return Err("该盘已是免密盘, 拒绝重复改造".into()),
        parser::DiskStatus::NotCems => return Err("非 cems 盘或结构异常".into()),
    }

    let usb = disk::list_usb_disks().into_iter().find(|d| d.disk == disk_no)
        .ok_or("目标 USB 盘已离线")?;
    let total = usb.size_bytes / 512;
    let vid = usb.vid;
    let pid = usb.pid;
    let lid = disk::read_lba(disk_no, 4)
        .map_err(|e| format!("读取 LBA4 唯一 ID 失败: {e}"))
        .and_then(|r| crypto::lba4_parse_serial(&r).ok_or("无法解析 LBA4 唯一 ID".to_string()))?;

    let mut sectors = std::collections::BTreeMap::new();
    let hx = |b: &[u8]| b.iter().map(|x| format!("{x:02x}")).collect::<String>();
    sectors.insert("0".to_string(), hx(&plan.lba0));
    sectors.insert("6".to_string(), hx(&plan.lba6));
    sectors.insert("7".to_string(), hx(&plan.lba7));
    sectors.insert("12".to_string(), hx(&plan.lba12));
    if let Some(l9) = &plan.lba9 { sectors.insert("9".to_string(), hx(l9)); }

    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let payload = convert::WritePayload {
        disk: disk_no,
        backup_dir: format!("{home}/Library/Application Support/EDPOpen/backups"),
        device_id: id.device_id,
        lid: Some(lid),
        vid,
        pid,
        total_sectors: Some(total),
        uid: unsafe { edpopen_getuid() },
        sectors,
    };
    let r = convert::write_sectors(payload)?;
    Ok(ApplyResult {
        ok: r.ok,
        backup_path: r.backup_path,
        written: r.written,
        verified: r.verified,
        error: r.error,
    })
}

extern "C" {
    #[link_name = "getuid"]
    fn edpopen_getuid_raw() -> u32;
}
unsafe fn edpopen_getuid() -> u32 { edpopen_getuid_raw() }

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
                for (size_index, &sz) in sizes.iter().enumerate() {
                    let mut buf = rand.to_vec();
                    buf.extend_from_slice(&vid);
                    buf.extend_from_slice(&pid);
                    buf.extend_from_slice(&sz.to_le_bytes());
                    let key = crypto::crc32_bare(&buf).to_le_bytes();
                    let pt = crypto::a6b0_full(&raw[0x100..], &key, 0);
                    if pt.starts_with(b"PDKB") {
                        let mut dec = rand.to_vec();
                        dec.extend_from_slice(&pt);
                        let label = if size_index == 0 { "DiskSize" } else { "CHS" };
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
