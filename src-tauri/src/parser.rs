//! parser.rs — MBR 分区表 / EDPF entry / 盘状态判定。
//! (任务#5 扩展 LBA4/6/8/11 全解析; 此处先做概览页所需的最小集)

use serde::Serialize;

pub const DOS_PART_TYPES: &[(u8, &str)] = &[
    (0x01, "FAT12"), (0x04, "FAT16"), (0x05, "Extended"), (0x06, "FAT16B"),
    (0x07, "NTFS/exFAT"), (0x0B, "FAT32(CHS)"), (0x0C, "FAT32(LBA)"),
    (0x0E, "FAT16(LBA)"), (0x0F, "Extended(LBA)"), (0x27, "Hidden NTFS"),
    (0x82, "Linux swap"), (0x83, "Linux"), (0xEE, "GPT Protective"), (0xEF, "EFI System"),
];

pub fn dos_type_name(t: u8) -> String {
    DOS_PART_TYPES.iter().find(|(k, _)| *k == t)
        .map(|(_, v)| v.to_string())
        .unwrap_or_else(|| format!("0x{t:02X}"))
}

/// EDPF entry 类型(与 nopwd.py PART_TYPES 一致)
pub fn edpf_type_name(t: u32) -> String {
    match t {
        1 => "Boot".into(),
        2 => "Share".into(),
        4 => "Encrypt/IIR指针".into(),
        _ => format!("type{t}"),
    }
}

// ── MBR ──────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, Serialize)]
pub struct MbrPart {
    pub index: u32,       // 1..=4
    pub bootable: bool,
    pub ptype: u8,
    pub type_name: String,
    pub start: u64,       // LBA
    pub sectors: u64,
}

pub fn parse_mbr(lba0: &[u8]) -> Option<Vec<MbrPart>> {
    if lba0.len() < 512 || &lba0[0x1FE..0x200] != b"\x55\xaa" { return None; }
    let mut parts = Vec::new();
    for i in 0..4 {
        let off = 0x1BE + i * 16;
        let ptype = lba0[off + 4];
        if ptype == 0 { continue; }
        let start = u32::from_le_bytes(lba0[off + 8..off + 12].try_into().unwrap()) as u64;
        let sectors = u32::from_le_bytes(lba0[off + 12..off + 16].try_into().unwrap()) as u64;
        parts.push(MbrPart {
            index: i as u32 + 1,
            bootable: lba0[off] == 0x80,
            ptype,
            type_name: dos_type_name(ptype),
            start,
            sectors,
        });
    }
    Some(parts)
}

// ── EDPF entry (LBA7 stride=0x40, LBA12 stride=0x60) ─────────────────────
#[derive(Debug, Clone, Serialize)]
pub struct EdpfEntry {
    pub index: usize,
    pub ver: u32,         // +0x08 (读端透传, 不参与判定)
    pub ptype: u32,       // +0x0C: 1=Boot 2=Share 4=Encrypt/IIR指针
    pub active: u32,      // +0x10
    pub enc_enable: u32,  // +0x14
    pub start: u64,       // +0x18 LBA
    pub bps: u64,         // +0x20
    pub size: u64,        // +0x28 字节
    pub pwd_crc: u32,     // +0x30
}

fn u32le(d: &[u8], off: usize) -> u32 { u32::from_le_bytes(d[off..off + 4].try_into().unwrap()) }
fn u64le(d: &[u8], off: usize) -> u64 { u64::from_le_bytes(d[off..off + 8].try_into().unwrap()) }

/// 解析解密后的 EDPF 表, 逐 entry 验 magic, 返回有效条目(≤3)
pub fn parse_edpf(dec: &[u8], stride: usize) -> Vec<EdpfEntry> {
    let mut out = Vec::new();
    for i in 0..3 {
        let e = &dec[i * stride..];
        if e.len() < stride || &e[..4] != b"EDPF" { break; }
        out.push(EdpfEntry {
            index: i,
            ver: u32le(e, 0x08),
            ptype: u32le(e, 0x0C),
            active: u32le(e, 0x10),
            enc_enable: u32le(e, 0x14),
            start: u64le(e, 0x18),
            bps: u64le(e, 0x20),
            size: u64le(e, 0x28),
            pwd_crc: u32le(e, 0x30),
        });
    }
    out
}

// ── 盘状态判定(判据: 项目记忆定案) ────────────────────────────────────────
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiskStatus {
    /// 标准加密盘: LBA12 3 条 entry(Boot/Share/Encrypt), MBR 指向 Boot 小分区, LBA9 有 EETU
    Encrypted,
    /// 免密盘/已改造: LBA12 2 条 entry(Share/Encrypt), MBR 首分区 == entry0(Share) 大小
    NoPwd,
    /// 非 cems 盘 / 无法判定
    NotCems,
}

/// 判定: 3条→标准加密盘; 2条 且 MBR 首分区扇数==entry0.size/512 → 免密;
/// LBA12 解不出 EDPF 由调用方先行排除。
pub fn classify(entries: &[EdpfEntry], mbr: &[MbrPart], lba9_nonzero: bool) -> DiskStatus {
    if entries.is_empty() { return DiskStatus::NotCems; }
    if entries.len() >= 3 { return DiskStatus::Encrypted; }
    if entries.len() == 2 {
        // entry0 应为 Share@63; MBR 首分区直挂同大小 → 免密形态
        if let (Some(e0), Some(p1)) = (entries.first(), mbr.first()) {
            let share_sectors = e0.size / 512;
            if e0.ptype == 2 && e0.start == 63 && p1.start == 63 && p1.sectors == share_sectors {
                return DiskStatus::NoPwd;
            }
            // 2 条但 MBR 仍是 Boot 小分区形态(如被自愈恢复过) → 按加密盘处理
            if p1.sectors < 65536 { return DiskStatus::Encrypted; }
        }
        return DiskStatus::NoPwd;
    }
    let _ = lba9_nonzero; // 辅助证据, 当前判据已足够; 保留参数供解析页展示
    DiskStatus::NotCems
}

/// 容量显示: GB(10^9) 两位小数四舍五入(整数截断到 0.01GB 后浮点格式化, 与 Python fmt_gb 一致)
pub fn fmt_gb(num_bytes: u64) -> String {
    format!("{:.2}GB", ((num_bytes + 5_000_000) / 10_000_000) as f64 / 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fmt_gb_matches_python() {
        assert_eq!(fmt_gb(124_736_503_808), "124.74GB");
        assert_eq!(fmt_gb(118_489_055_744), "118.49GB");
        assert_eq!(fmt_gb(6_234_963_968), "6.23GB");
    }

    #[test]
    fn classify_rules() {
        let mk = |ptype: u32, start: u64, size: u64| EdpfEntry {
            index: 0, ver: 2, ptype, active: 1, enc_enable: 1, start, bps: 512, size, pwd_crc: 0,
        };
        let boot = MbrPart { index: 1, bootable: false, ptype: 0x0E, type_name: "FAT16".into(), start: 63, sectors: 20417 };
        // 3 条 → 加密盘
        assert_eq!(classify(&[mk(1, 63, 20417 * 512), mk(2, 20480, 1), mk(4, 100, 3072)], &[boot.clone()], true), DiskStatus::Encrypted);
        // 2 条 + MBR 直挂 Share 同大小 → 免密
        let share = MbrPart { index: 1, bootable: false, ptype: 0x07, type_name: "NTFS".into(), start: 63, sectors: 117_611_802 };
        assert_eq!(classify(&[mk(2, 63, 117_611_802 * 512), mk(4, 117_611_865, 3072)], &[share], false), DiskStatus::NoPwd);
        // 2 条但 MBR 还是 Boot 小分区(自愈恢复态) → 加密盘
        assert_eq!(classify(&[mk(2, 63, 1), mk(4, 100, 3072)], &[boot], true), DiskStatus::Encrypted);
    }
}
