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

// LBA6_TEMPLATE — DLL 0x100E7220 的 512B MBR 引导扇区模板(read_metadata 同源),
// 用于 LBA6 解密后标注标签数据覆盖模板的字段边界。
pub const LBA6_TEMPLATE: [u8; 512] = [
    0x33,0xc0,0x8e,0xd0,0xbc,0x00,0x7c,0xfb,0x50,0x07,0x50,0x1f,0xfc,0xbe,0x1b,0x7c,
    0xbf,0x1b,0x06,0x50,0x57,0xb9,0xe5,0x01,0xf3,0xa4,0xcb,0xbd,0xbe,0x07,0xb1,0x04,
    0x38,0x6e,0x00,0x7c,0x09,0x75,0x13,0x83,0xc5,0x10,0xe2,0xf4,0xcd,0x18,0x8b,0xf5,
    0x83,0xc6,0x10,0x49,0x74,0x19,0x38,0x2c,0x74,0xf6,0xa0,0xb5,0x07,0xb4,0x07,0x8b,
    0xf0,0xac,0x3c,0x00,0x74,0xfc,0xbb,0x07,0x00,0xb4,0x0e,0xcd,0x10,0xeb,0xf2,0x88,
    0x4e,0x10,0xe8,0x46,0x00,0x73,0x2a,0xfe,0x46,0x10,0x80,0x7e,0x04,0x0b,0x74,0x0b,
    0x80,0x7e,0x04,0x0c,0x74,0x05,0xa0,0xb6,0x07,0x75,0xd2,0x80,0x46,0x02,0x06,0x83,
    0x46,0x08,0x06,0x83,0x56,0x0a,0x00,0xe8,0x21,0x00,0x73,0x05,0xa0,0xb6,0x07,0xeb,
    0x00,0x81,0x3e,0xfe,0x7d,0x55,0xaa,0x74,0x0b,0x80,0x7e,0x10,0x00,0x74,0xc8,0xa0,
    0xb7,0x07,0xeb,0xa9,0x8b,0xfc,0x1e,0x57,0x8b,0xf5,0xcb,0xbf,0x05,0x00,0x8a,0x56,
    0x00,0xb4,0x08,0xcd,0x13,0x72,0x23,0x8a,0xc1,0x24,0x3f,0x98,0x8a,0xde,0x8a,0xfc,
    0x43,0xf7,0xe3,0x8b,0xd1,0x86,0xd6,0xb1,0x06,0xd2,0xee,0x42,0xf7,0xe2,0x39,0x56,
    0x0a,0x77,0x23,0x72,0x05,0x39,0x46,0x08,0x73,0x1c,0xb8,0x01,0x02,0xbb,0x00,0x7c,
    0x8b,0x4e,0x02,0x8b,0x56,0x00,0xcd,0x13,0x73,0x51,0x4f,0x74,0x4e,0x32,0xe4,0x8a,
    0x56,0x00,0xcd,0x13,0xeb,0xe4,0x8a,0x56,0x00,0x60,0xbb,0xaa,0x55,0xb4,0x41,0xcd,
    0x13,0x72,0x36,0x81,0xfb,0x55,0xaa,0x75,0x30,0xf6,0xc1,0x01,0x74,0x2b,0x61,0x60,
    0x6a,0x00,0x6a,0x00,0xff,0x76,0x0a,0xff,0x76,0x08,0x6a,0x00,0x68,0x00,0x7c,0x6a,
    0x01,0x6a,0x10,0xb4,0x42,0x8b,0xf4,0xcd,0x13,0x61,0x61,0x73,0x0e,0x4f,0x74,0x0b,
    0x32,0xe4,0x8a,0x56,0x00,0xcd,0x13,0xeb,0xd6,0x61,0xf9,0xc3,0x49,0x6e,0x76,0x61,
    0x6c,0x69,0x64,0x20,0x70,0x61,0x72,0x74,0x69,0x74,0x69,0x6f,0x6e,0x20,0x74,0x61,
    0x62,0x6c,0x65,0x00,0x45,0x72,0x72,0x6f,0x72,0x20,0x6c,0x6f,0x61,0x64,0x69,0x6e,
    0x67,0x20,0x6f,0x70,0x65,0x72,0x61,0x74,0x69,0x6e,0x67,0x20,0x73,0x79,0x73,0x74,
    0x65,0x6d,0x00,0x4d,0x69,0x73,0x73,0x69,0x6e,0x67,0x20,0x6f,0x70,0x65,0x72,0x61,
    0x74,0x69,0x6e,0x67,0x20,0x73,0x79,0x73,0x74,0x65,0x6d,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x2c,0x44,0x63,0x46,0x28,0x77,0x09,0x00,0x00,0x00,0x01,
    0x01,0x00,0x07,0xfe,0x3f,0x0f,0x3f,0x00,0x00,0x00,0xe0,0xf5,0x01,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x55,0xaa,
];

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

// ══════════════════════════════════════════════════════════════════════════
// 字段表(FieldRow) — 扇区页着色/hover 与盘地图 tooltip 的统一数据源。
// color 语义: magic=标识 / part=分区布局 / key=密钥材料 / label=标签文本 /
//            cipher=密文 / checksum=校验 / warn=敏感区(编辑警示)
// ══════════════════════════════════════════════════════════════════════════
#[derive(Debug, Clone, Serialize)]
pub struct FieldRow {
    pub off: usize,       // 在对应视图(raw 或 dec)中的偏移
    pub len: usize,
    pub name: String,
    pub desc: String,
    pub value: String,
    pub color: String,
}

fn field(off: usize, len: usize, name: &str, desc: &str, value: String, color: &str) -> FieldRow {
    FieldRow { off, len, name: name.into(), desc: desc.into(), value, color: color.into() }
}

fn gbk(bytes: &[u8]) -> String {
    encoding_rs::GBK.decode(bytes).0.into_owned()
}

/// null 结尾 GBK 串
fn gbk_z(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    gbk(&bytes[..end])
}

pub fn lba0_fields(raw: &[u8]) -> Vec<FieldRow> {
    let mut f = vec![field(0, 0x1BE, "引导代码", "MBR 引导区(与改造无关)", String::new(), "cipher")];
    for i in 0..4 {
        let off = 0x1BE + i * 16;
        let ptype = raw[off + 4];
        if ptype == 0 { continue; }
        let start = u32le(raw, off + 8) as u64;
        let sectors = u32le(raw, off + 12) as u64;
        f.push(field(off, 16, &format!("分区表项{i}"),
            "MBR 分区项(boot/type/CHS/起始LBA/扇数)",
            format!("{} @LBA{} ×{}扇 ({})", dos_type_name(ptype), start, sectors, fmt_gb(sectors * 512)), "part"));
    }
    f.push(field(0x1FE, 2, "55AA", "MBR 签名", "55 AA".into(), "magic"));
    f
}

pub fn lba4_fields(dec: &[u8]) -> Vec<FieldRow> {
    let mut f = Vec::new();
    if let Some(serial) = crate::crypto::lba4_parse_serial(dec) {
        let lid = (serial & 0xFFFF_FFFF) as u32;
        f.push(field(0, 16, "$$$ 标签头", "labelOnlyId(盘唯一 ID, 明文)", format!("$$$ {serial} $$$ (0x{lid:08X})"), "magic"));
        f.push(field(0x18, 4, "onlyIdXor8", "= labelOnlyId ^ 0x88888888(上传服务器)",
            format!("0x{:08X}", u32le(dec, 0x18)), "key"));
        f.push(field(0x1C, 4, "onlyID2Nd", "独立盘唯一 ID(sectorInfo AES key 种子)",
            format!("0x{:08X}", u32le(dec, 0x1C)), "key"));
        f.push(field(0x20, 8, "device-unique", "设备唯一块", hex(&dec[0x20..0x28]), "key"));
    } else {
        f.push(field(0, 64, "标签头", "未找到 $$$<数字>$$$ 头", String::new(), "cipher"));
    }
    if &dec[0x39..0x3D] == b"LLGB" {
        f.push(field(0x39, 4, "LLGB 锚点", "LLGB 关联段起点(与 LBA8 呼应)", "LLGB".into(), "magic"));
    }
    f
}

/// LBA6 SAFE6 字段(基于 LBA6_TEMPLATE 边界标注; crc_expected 用于 CRC 比对)
pub fn lba6_fields(dec: &[u8], crc_expected: u32) -> Vec<FieldRow> {
    let mut f = Vec::new();
    f.push(field(0x00, 64, "标签名", "GBK 标签文本(覆盖模板)", format!("\"{}\"", gbk_z(&dec[0x00..0x40])), "label"));
    f.push(field(0x50, 32, "用户", "GBK 责任人", format!("\"{}\"", gbk_z(&dec[0x50..0x70])), "label"));
    f.push(field(0x70, 16, "序列号", "ASCII", format!("\"{}\"", gbk_z(&dec[0x70..0x80])), "label"));
    let crc = u32le(dec, 0x100);
    f.push(field(0x100, 4, "CRC32(device_id)", "盘身份绑定",
        format!("0x{crc:08X} {}", if crc == crc_expected { "✓" } else { "✗" }), "key"));
    f.push(field(0x104, 4, "CRC32<<1", "上字段的移位副本",
        format!("0x{:08X} {}", u32le(dec, 0x104), if u32le(dec, 0x104) == crc.wrapping_shl(1) { "✓" } else { "✗" }), "key"));
    if dec[0x188..0x1C0].windows(6).any(|w| w == b"!SAFE6") {
        let pos = dec[0x188..0x1C0].windows(6).position(|w| w == b"!SAFE6").unwrap();
        f.push(field(0x188, pos + 6, "GBK+!SAFE6", "部门名+签名", format!("\"{}!SAFE6\"", gbk_z(&dec[0x188..0x188 + pos])), "label"));
    }
    f.push(field(0x1C0, 8, "GLAB 前缀", "标签编号前缀", format!("\"{}\"", String::from_utf8_lossy(&dec[0x1C0..0x1C8])), "label"));
    f.push(field(0x1CA, 2, "0x1CA", "模板默认/Boot 扇区数(语义未定案, 非数据区大小)",
        format!("{}", u16::from_le_bytes([dec[0x1CA], dec[0x1CB]])), "cipher"));
    f.push(field(0x1D4, 25, "旧分区描述", "加密盘分区描述符(改造时清零区)", String::new(), "cipher"));
    f.push(field(0x1F0, 1, "注册标志", "已注册=1", format!("{}", dec[0x1F0]), "key"));
    f.push(field(0x1FC, 4, "校验和", "对密文 CRC32 的 ROL1×10 变换",
        format!("0x{:08X}", u32le(dec, 0x1FC)), "checksum"));
    f
}

fn edpf_entry_fields(f: &mut Vec<FieldRow>, dec: &[u8], stride: usize, idx: usize) {
    let base = idx * stride;
    let e = &dec[base..];
    if &e[..4] != b"EDPF" { return; }
    let ptype = u32le(e, 0x0C);
    let name = format!("entry{idx}·{}", edpf_type_name(ptype));
    f.push(field(base, 4, &format!("{name} magic"), "EDPF 标识", "EDPF".into(), "magic"));
    f.push(field(base + 0x08, 4, &format!("{name} 版本"), "结构版本(读端透传)", format!("{}", u32le(e, 0x08)), "cipher"));
    f.push(field(base + 0x0C, 4, &format!("{name} 类型"), "1=Boot 2=Share 4=Encrypt/IIR指针", format!("{}", ptype), "part"));
    f.push(field(base + 0x10, 4, &format!("{name} 激活"), "激活标志", format!("{}", u32le(e, 0x10)), "part"));
    f.push(field(base + 0x14, 4, &format!("{name} 加密使能"), "+0x14=加密使能(非只读)", format!("{}", u32le(e, 0x14)), "part"));
    f.push(field(base + 0x18, 8, &format!("{name} 起始"), "起始 LBA", format!("{}", u64le(e, 0x18)), "part"));
    f.push(field(base + 0x20, 8, &format!("{name} bps"), "每扇字节数", format!("{}", u64le(e, 0x20)), "cipher"));
    f.push(field(base + 0x28, 8, &format!("{name} 大小"), "字节(Encrypt 在 LBA7 为 3072B IIR 指针)",
        format!("{} ({})", u64le(e, 0x28), fmt_gb(u64le(e, 0x28))), "part"));
    f.push(field(base + 0x30, 4, &format!("{name} pwdCRC"), "CRC32(密码); 0x0429735D=默认密码 0000aaaa",
        format!("0x{:08X}", u32le(e, 0x30)), "key"));
    if stride == 0x40 {
        f.push(field(base + 0x38, 8, &format!("{name} key8"), "密钥材料(Region A 上级)", hex(&e[0x38..0x40]), "key"));
    } else {
        f.push(field(base + 0x34, 4, &format!("{name} keyCRC"), "CRC32(file_key) 闭合校验", format!("0x{:08X}", u32le(e, 0x34)), "key"));
        f.push(field(base + 0x40, 16, &format!("{name} salt"), "file_key 的 wrapped salt", hex(&e[0x40..0x50]), "key"));
        f.push(field(base + 0x60, 4, &format!("{name} algo"), "加密算法: 2=SM4 1=AES", format!("{}", u32le(e, 0x60)), "key"));
    }
}

pub fn lba7_fields(dec: &[u8]) -> Vec<FieldRow> {
    let mut f = Vec::new();
    for i in 0..3 { edpf_entry_fields(&mut f, dec, 0x40, i); }
    if dec[0xC0..0xC8] != [0; 8] {
        f.push(field(0xC0, 8, "表尾终止符", "EDPF 表结束标记(不清零铁律)", hex(&dec[0xC0..0xC8]), "warn"));
    }
    f
}

pub fn lba12_fields(dec: &[u8]) -> Vec<FieldRow> {
    let mut f = Vec::new();
    for i in 0..2 { edpf_entry_fields(&mut f, dec, 0x60, i); }
    if dec[0x120..0x128] != [0; 8] {
        f.push(field(0x120, 8, "表尾终止符", "EDPF 表结束标记(不清零铁律)", hex(&dec[0x120..0x128]), "warn"));
    }
    f
}

pub fn lba8_fields(dec: &[u8]) -> Vec<FieldRow> {
    let mut f = Vec::new();
    if dec.starts_with(b"LLGB") {
        f.push(field(0, 4, "LLGB magic", "标签分区(LLGB)标识", "LLGB".into(), "magic"));
        f.push(field(4, 4, "长度", "结构长度", format!("{}", u32le(dec, 4)), "cipher"));
    }
    for t in parse_elabel(dec) {
        f.push(field(t.off, t.len, &format!("<{}>", t.tag), "ELABEL 标签键值", t.kvs.join("  ||  "), "label"));
    }
    f
}

pub fn lba9_fields(dec: &[u8]) -> Vec<FieldRow> {
    let mut f = Vec::new();
    if dec.iter().all(|&b| b == 0) {
        f.push(field(0, 512, "全零", "无 EETU(免密盘特征)", String::new(), "zero"));
    } else {
        f.push(field(0, 128, "EETU", "临时使用区(A6B0 加密)", String::new(), "cipher"));
        f.push(field(0x100, 32, "XOR0x88 区", "0x88 混淆段", String::new(), "cipher"));
    }
    f
}

pub fn lba11_fields(dec: &[u8]) -> Vec<FieldRow> {
    let mut f = Vec::new();
    f.push(field(0, 256, "rand", "DRKB 头+随机明文(key 组成部分)", String::new(), "key"));
    if &dec[0x100..0x104] == b"PDKB" {
        let dev = dec[0x104..].iter().position(|&b| b == 0).unwrap_or(108);
        f.push(field(0x100, 4, "PDKB magic", "设备备份块标识", "PDKB".into(), "magic"));
        f.push(field(0x104, dev, "device_id", "盘身份(解 LBA7/8/12 的 key 源)", gbk(&dec[0x104..0x104 + dev]), "label"));
    } else {
        f.push(field(0x100, 256, "PDKB 密文", "未解出(需正确 VID/PID/DiskSize)", String::new(), "cipher"));
    }
    f
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// ── 结构化解析(golden 对拍用, fields 函数同源) ────────────────────────────
#[derive(Debug, Clone, Serialize)]
pub struct Lba4Info {
    pub serial: u64,
    pub xor8: String,
    pub second: String,
    pub llgb: bool,
}

pub fn parse_lba4_info(dec: &[u8]) -> Option<Lba4Info> {
    let serial = crate::crypto::lba4_parse_serial(dec)?;
    Some(Lba4Info {
        serial,
        xor8: format!("{:08X}", u32le(dec, 0x18)),
        second: format!("{:08X}", u32le(dec, 0x1C)),
        llgb: &dec[0x39..0x3D] == b"LLGB",
    })
}

#[derive(Debug, Clone, Serialize)]
pub struct Lba6Info {
    pub label: String,
    pub user: String,
    pub serial_ascii: String,
    pub crc_ok: bool,
    pub crc_l1_ok: bool,
    pub safe6: bool,
    pub glab: String,
    pub flag_1f0: u8,
    pub reg_1ca: u16,
}

pub fn parse_lba6_info(dec: &[u8], crc: u32) -> Lba6Info {
    Lba6Info {
        label: gbk_z(&dec[0x00..0x40]),
        user: gbk_z(&dec[0x50..0x70]),
        serial_ascii: String::from_utf8_lossy(&{
            let end = dec[0x70..0x80].iter().position(|&b| b == 0).unwrap_or(16);
            dec[0x70..0x70 + end].to_vec()
        }).into_owned(),
        crc_ok: u32le(dec, 0x100) == crc,
        crc_l1_ok: u32le(dec, 0x104) == crc.wrapping_shl(1),
        safe6: dec[0x188..0x1C0].windows(6).any(|w| w == b"!SAFE6"),
        glab: String::from_utf8_lossy(&{
            let end = dec[0x1C0..0x1C8].iter().position(|&b| b == 0).unwrap_or(8);
            dec[0x1C0..0x1C0 + end].to_vec()
        }).into_owned(),
        flag_1f0: dec[0x1F0],
        reg_1ca: u16::from_le_bytes([dec[0x1CA], dec[0x1CB]]),
    }
}

// ── LBA8 ELABEL(show_llgb 移植, 字节级 split 防 GBK 吞管道符) ─────────────
#[derive(Debug, Clone, Serialize)]
pub struct ElabelTag {
    pub off: usize,
    pub len: usize,
    pub tag: String,
    pub kvs: Vec<String>,
}

pub fn parse_elabel(dec: &[u8]) -> Vec<ElabelTag> {
    // 从 0x80 起找首个 '<'; 无则无 ELABEL
    let Some(mut i) = dec.iter().skip(0x80).position(|&b| b == b'<').map(|p| p + 0x80) else {
        return Vec::new();
    };
    let mut tags = Vec::new();
    while i < dec.len() {
        if dec[i] != 0x3C { i += 1; continue; }
        if i + 1 < dec.len() && dec[i + 1] == 0x2F {          // 关闭标签 </TAG>
            match dec[i..].iter().position(|&b| b == b'>') {
                Some(e) => { i += e + 1; continue; }
                None => { i += 1; continue; }
            }
        }
        // 开启标签 <TAG>
        let Some(end) = dec[i..].iter().position(|&b| b == b'>') else { break };
        let tag = gbk(&dec[i + 1..i + end]);
        let start = i + end + 1;
        let find2 = |from: usize, pat: &[u8]| -> Option<usize> {
            dec[from..].windows(2).position(|w| w == pat).map(|p| from + p)
        };
        let content_end = find2(start, b"</")
            .or_else(|| find2(start, b"\x00\x00"))
            .unwrap_or(dec.len());
        let content = &dec[start..content_end];
        let trimmed = trim_zeros_end(content);
        // 字节级 split(b"||") 后逐段 GBK(防 GBK trail byte 0x7C 吞管道符)
        let mut kvs = Vec::new();
        let mut last = 0usize;
        let mut j = 0usize;
        while j + 1 < trimmed.len() {
            if &trimmed[j..j + 2] == b"||" {
                if !trimmed[last..j].is_empty() { kvs.push(gbk(&trimmed[last..j])); }
                j += 2;
                last = j;
            } else {
                j += 1;
            }
        }
        if !trimmed[last..].is_empty() { kvs.push(gbk(&trimmed[last..])); }
        tags.push(ElabelTag { off: i, len: content_end - i, tag, kvs });
        i = content_end;
    }
    tags
}

fn trim_zeros_end(mut b: &[u8]) -> &[u8] {
    while let Some((&0, rest)) = b.split_last() { b = rest; }
    b
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
