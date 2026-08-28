//! disk.rs — 盘枚举(diskutil plist) / ioreg INQUIRY / device_id 两候选识别 / 扇区读。
//! 读无需提权: macOS 把热插拔盘 /dev/rdiskN chown 给当前用户(只读)。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::process::Command;

use crate::crypto::{crc32_bare, xor_rolling};

pub const SECTOR: usize = 512;

#[derive(Debug, Clone, serde::Serialize)]
pub struct UsbDisk {
    pub disk: u32,
    pub size_bytes: u64,
    pub vid: String,
    pub pid: String,
}

fn cmd_out(prog: &str, args: &[&str]) -> Option<String> {
    Command::new(prog)
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
}

// ── 盘枚举 ────────────────────────────────────────────────────────────────
pub fn list_usb_disks() -> Vec<UsbDisk> {
    let mut out = Vec::new();
    let Some(plist_txt) = cmd_out("diskutil", &["list", "-plist"]) else { return out };
    let Ok(pl) = plist::Value::from_reader(std::io::Cursor::new(plist_txt.as_bytes())) else { return out };
    let Some(all) = pl.as_dictionary().and_then(|d| d.get("AllDisks")).and_then(|v| v.as_array()) else { return out };
    for name in all.iter().filter_map(|v| v.as_string()) {
        // 只要整盘 diskN, 排除 disk4s1 分区; 系统盘 disk0/1 不进入候选
        let Some(rest) = name.strip_prefix("disk") else { continue };
        let Ok(n) = rest.parse::<u32>() else { continue };
        if n < 2 { continue; }
        let Some(info) = cmd_out("diskutil", &["info", "-plist", name]) else { continue };
        let Ok(pl) = plist::Value::from_reader(std::io::Cursor::new(info.as_bytes())) else { continue };
        let Some(d) = pl.as_dictionary() else { continue };
        let whole = d.get("WholeDisk").and_then(|v| v.as_boolean()).unwrap_or(false);
        let internal = d.get("Internal").and_then(|v| v.as_boolean()).unwrap_or(true);
        let usb = d.get("BusProtocol").and_then(|v| v.as_string()).map(|s| s == "USB").unwrap_or(false);
        if !whole || internal || !usb { continue; }
        let size = d.get("TotalSize")
            .or_else(|| d.get("DiskSize"))
            .or_else(|| d.get("Size"))
            .and_then(|v| v.as_unsigned_integer())
            .unwrap_or(0);
        if size == 0 { continue; }
        let (vid, pid) = usb_vid_pid(n).unwrap_or(("0000".into(), "0000".into()));
        out.push(UsbDisk { disk: n, size_bytes: size, vid, pid });
    }
    out
}

// ── ioreg ────────────────────────────────────────────────────────────────
/// 取 ioreg 指定类的块列表(以 `+-o <cls>` 分块)
fn ioreg_blocks(cls: &str) -> Vec<String> {
    match cmd_out("ioreg", &["-r", "-c", cls, "-l"]) {
        Some(out) => out
            .split(&format!("+-o {cls}"))
            .skip(1)
            .map(|s| s.to_string())
            .collect(),
        None => Vec::new(),
    }
}

fn block_for_disk(cls: &str, disk: u32) -> Option<String> {
    let want = format!("\"BSD Name\" = \"disk{disk}\"");
    ioreg_blocks(cls).into_iter().find(|b| b.contains(&want))
}

/// USB VID/PID(hex4) — IOUSBHostDevice 块内 idVendor/idProduct
pub fn usb_vid_pid(disk: u32) -> Option<(String, String)> {
    let b = block_for_disk("IOUSBHostDevice", disk)?;
    let re = regex::Regex::new(r#""idVendor"\s*=\s*(\d+)"#).ok()?;
    let rp = regex::Regex::new(r#""idProduct"\s*=\s*(\d+)"#).ok()?;
    let v: u64 = re.captures(&b)?.get(1)?.as_str().parse().ok()?;
    let p: u64 = rp.captures(&b)?.get(1)?.as_str().parse().ok()?;
    Some((format!("{v:04x}"), format!("{p:04x}")))
}

fn norm(s: &str) -> String {
    s.trim_end_matches(' ').replace(' ', "_").to_lowercase()
}

/// SCSI INQUIRY 三字段
fn inquiry(disk: u32) -> Option<(String, String, String)> {
    for cls in ["IOSCSITargetDevice", "IOSCSILogicalUnitNub", "IOSCSIPeripheralDeviceNub"] {
        let b = block_for_disk(cls, disk)?;
        let g = |key: &str| {
            let re = regex::Regex::new(&format!(r#""{key}"\s*=\s*"([^"]*)""#)).unwrap();
            re.captures(&b).map(|c| c[1].to_string())
        };
        if let Some(v) = g("Vendor Identification") {
            return Some((v, g("Product Identification").unwrap_or_default(), g("Product Revision Level").unwrap_or_default()));
        }
    }
    None
}

/// 传输模式: UAS / BOT / UNKNOWN
fn detect_transport(disk: u32) -> &'static str {
    for cls in ["IOUSBMassStorageUASDriver", "IOUSBMassStorageInterfaceNub", "IOUSBMassStorageDriver"] {
        if let Some(out) = cmd_out("ioreg", &["-r", "-c", cls, "-l"]) {
            if out.contains(&format!("\"BSD Name\" = \"disk{disk}\"")) {
                return if cls == "IOUSBMassStorageUASDriver" { "UAS" } else { "BOT" };
            }
        }
    }
    "UNKNOWN"
}

/// Windows InstanceId 中间段: BOT(usbstor)含 &rev_, UAS(uaspstor)通常不含
fn build_device_id(vendor: &str, product: &str, revision: &str, transport: &str) -> String {
    let base = format!("disk&ven_{}&prod_{}", norm(vendor), norm(product));
    if transport == "BOT" && !norm(revision).is_empty() {
        format!("{base}&rev_{}", norm(revision))
    } else {
        base
    }
}

/// 两候选: 按传输模式排序(UAS 短版优先, BOT 长版优先)
pub fn generate_candidates(disk: u32) -> Vec<String> {
    let mut cs = Vec::new();
    if let Some((v, p, rev)) = inquiry(disk) {
        let long_id = build_device_id(&v, &p, &rev, "BOT");
        let short_id = build_device_id(&v, &p, &rev, "UAS");
        match detect_transport(disk) {
            "UAS" => { cs.push(short_id); cs.push(long_id); }
            _ => { cs.push(long_id); cs.push(short_id); }
        }
    }
    cs
}

// ── 扇区读 ────────────────────────────────────────────────────────────────
pub fn read_lba(disk: u32, lba: u64) -> std::io::Result<Vec<u8>> {
    let mut f = File::open(format!("/dev/rdisk{disk}"))?;
    f.seek(SeekFrom::Start(lba * SECTOR as u64))?;
    let mut buf = vec![0u8; SECTOR];
    f.read_exact(&mut buf)?;
    Ok(buf)
}

// ── device_id 识别(LBA7 EDPF magic 判真) ─────────────────────────────────
pub fn lba7_k0(crc: u32) -> u16 {
    ((crc & 0xFFFF) ^ ((crc >> 16) & 0xFFFF)) as u16
}

pub struct Identity {
    pub device_id: String,
    pub crc: u32,
    pub k0: u16,
}

/// 返回 (device_id, crc32, k0); 两候选均失败返回 None
pub fn identify(disk: u32) -> Option<Identity> {
    let raw = read_lba(disk, 7).ok()?;
    for c in generate_candidates(disk) {
        let crc = crc32_bare(c.as_bytes());
        let k0 = lba7_k0(crc);
        if xor_rolling(&raw, k0).starts_with(b"EDPF") {
            return Some(Identity { device_id: c, crc, k0 });
        }
    }
    None
}
