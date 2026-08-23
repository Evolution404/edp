//! ioreg 文本输出解析：IOUSBHostDevice / SCSI INQUIRY / 传输模式绑定。

use edp_core::device::{InquirySources, Transport};
use regex::Regex;
use std::sync::OnceLock;

fn ioreg_output(class: &str) -> Option<String> {
    let out = std::process::Command::new("ioreg")
        .args(["-r", "-c", class, "-l"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

/// 按 `+-o <class>` 分块；返回包含指定 BSD Name 的块。
fn block_for(out: &str, class: &str, bsd: &str) -> Option<String> {
    let want = format!("\"BSD Name\" = \"{bsd}\"");
    let marker = format!("+-o {class}");
    let mut blocks: Vec<String> = Vec::new();
    let mut cur: Vec<&str> = Vec::new();
    for line in out.lines() {
        if line.contains(&marker) {
            if !cur.is_empty() {
                blocks.push(cur.join("\n"));
            }
            cur.clear();
        }
        cur.push(line);
    }
    if !cur.is_empty() {
        blocks.push(cur.join("\n"));
    }
    blocks.into_iter().find(|b| b.contains(&want))
}

fn field_str(block: &str, key: &str) -> Option<String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r#""([^"]+)"\s*=\s*"([^"]*)""#).unwrap());
    for cap in re.captures_iter(block) {
        if &cap[1] == key {
            return Some(cap[2].to_string());
        }
    }
    None
}

fn field_u32(block: &str, key: &str) -> Option<u32> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r#""([^"]+)"\s*=\s*(\d+)"#).unwrap());
    for cap in re.captures_iter(block) {
        if &cap[1] == key {
            return cap[2].parse().ok();
        }
    }
    None
}

/// LBA11 参数：(vid_hex, pid_hex, size_bytes)。
pub fn lba11_params(disk_num: u32) -> Option<(String, String, u64)> {
    let out = ioreg_output("IOUSBHostDevice")?;
    let bsd = format!("disk{disk_num}");
    let block = block_for(&out, "IOUSBHostDevice", &bsd)?;
    let vid = field_u32(block.as_str(), "idVendor")?;
    let pid = field_u32(block.as_str(), "idProduct")?;
    let size = crate::disk_size(&bsd).ok().filter(|&s| s > 0)?;
    Some((format!("{vid:04x}"), format!("{pid:04x}"), size))
}

/// SCSI INQUIRY（IOSCSITargetDevice 优先，兼容劫持场景的多级回退）。
fn inquiry(disk_num: u32) -> Option<(String, String, String)> {
    let bsd = format!("disk{disk_num}");
    for class in [
        "IOSCSITargetDevice",
        "IOSCSILogicalUnitNub",
        "IOSCSIPeripheralDeviceNub",
    ] {
        let Some(out) = ioreg_output(class) else {
            continue;
        };
        let Some(block) = block_for(&out, class, &bsd) else {
            continue;
        };
        let vendor = field_str(block.as_str(), "Vendor Identification");
        if let Some(v) = vendor {
            if v.is_empty() {
                continue;
            }
            let product = field_str(block.as_str(), "Product Identification").unwrap_or_default();
            let rev = field_str(block.as_str(), "Product Revision Level").unwrap_or_default();
            return Some((v, product, rev));
        }
    }
    None
}

/// 传输模式：UAS(uaspstor) / BOT(usbstor) / Unknown。
fn detect_transport(disk_num: u32) -> Transport {
    let bsd = format!("disk{disk_num}");
    for cls in [
        "IOUSBMassStorageUASDriver",
        "IOUSBMassStorageInterfaceNub",
        "IOUSBMassStorageDriver",
    ] {
        if let Some(out) = ioreg_output(cls) {
            if out.contains(&format!("\"BSD Name\" = \"{bsd}\"")) {
                return if cls == "IOUSBMassStorageUASDriver" {
                    Transport::Uas
                } else {
                    Transport::Bot
                };
            }
        }
    }
    Transport::Unknown
}

/// USB BOT 描述符回退（SCSI 层被劫持时）：(manufacturer, product)。
fn usb_desc(disk_num: u32) -> Option<(String, String)> {
    let out = ioreg_output("IOUSBMassStorageInterfaceNub")?;
    let bsd = format!("disk{disk_num}");
    let block = block_for(&out, "IOUSBMassStorageInterfaceNub", &bsd)?;
    let product = field_str(block.as_str(), "Product")?;
    let manu = field_str(block.as_str(), "Manufacturer").unwrap_or_default();
    Some((manu, product))
}

/// 组装 identify 候选来源。
pub fn inquiry_sources(disk_num: u32) -> InquirySources {
    InquirySources {
        inquiry: inquiry(disk_num),
        transport: detect_transport(disk_num),
        usb_desc: usb_desc(disk_num),
        media_name: {
            let bsd = format!("disk{disk_num}");
            crate::disk_size(&bsd).ok().and_then(|_| media_name(&bsd))
        },
    }
}

fn media_name(bsd: &str) -> Option<String> {
    let out = std::process::Command::new("diskutil")
        .args(["info", "-plist"])
        .arg(bsd)
        .output()
        .ok()?;
    let v: plist::Value = plist::from_bytes(&out.stdout).ok()?;
    let name = v
        .as_dictionary()?
        .get("MediaName")?
        .as_string()?
        .trim()
        .to_string();
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 多块输出下正确切分并按 BSD Name 命中目标块。
    #[test]
    fn block_splitting() {
        let out = "+-o IOUSBHostDevice\n  | \"idVendor\" = 1\n  |   \"BSD Name\" = \"disk9\"\n+-o IOUSBHostDevice\n  | \"idProduct\" = 2\n  |   \"BSD Name\" = \"disk4\"\n";
        let b = block_for(out, "IOUSBHostDevice", "disk4").unwrap();
        assert!(b.contains("idProduct"));
        assert!(!b.contains("idVendor"));
        assert!(block_for(out, "IOUSBHostDevice", "disk8").is_none());
    }
}
