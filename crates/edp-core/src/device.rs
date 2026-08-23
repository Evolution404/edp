//! device_id 候选生成（identify_disk.py 纯函数移植）。
//!
//! device_id 是 Windows USBSTOR Instance ID 的中间段：`disk&ven_<vendor>&prod_<product>[&rev_<rev>]`。
//! 系统层（edp-macos）提供 INQUIRY 的 vendor/product/revision 与传输模式、
//! USB 描述符、diskutil MediaName 回退；本模块只做确定性的字符串构造。

/// 传输模式（决定 &rev_ 是否进入 device_id 的先验顺序）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Transport {
    /// Bulk-Only Transport（usbstor，device ID 通常含 &rev_）。
    Bot,
    /// USB Attached SCSI（uaspstor，通常省略 &rev_）。
    Uas,
    #[default]
    Unknown,
}

/// 归一化：去尾空格 → 空格转下划线 → 小写（不合并连续下划线，
/// 与 Windows usbstor.sys 对齐，SanDisk 3.2Gen1 的双下划线由此保留）。
pub fn norm(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    s.trim_end_matches(' ').replace(' ', "_").to_lowercase()
}

/// 由 INQUIRY 字段 + 传输模式构造 device_id（BOT 强制含 &rev_，其余不含）。
pub fn build_device_id(
    vendor: &str,
    product: &str,
    revision: &str,
    transport: Transport,
) -> String {
    let base = format!("disk&ven_{}&prod_{}", norm(vendor), norm(product));
    if transport == Transport::Bot {
        let r = norm(revision);
        if !r.is_empty() {
            return format!("{base}&rev_{r}");
        }
    }
    base
}

/// 候选来源集合（系统层采集后传入）。
#[derive(Debug, Clone, Default)]
pub struct InquirySources {
    /// SCSI INQUIRY：vendor / product / revision。
    pub inquiry: Option<(String, String, String)>,
    /// 传输模式。
    pub transport: Transport,
    /// USB BOT 描述符回退 (manufacturer, product)。
    pub usb_desc: Option<(String, String)>,
    /// diskutil MediaName 回退（vendor 缺失时）。
    pub media_name: Option<String>,
}

/// 生成 device_id 候选（长版含 rev / 短版去 rev，按 transport 定顺序，
/// 两候选都试、由 LBA7 EDPF magic 判真——与厂商 DLL sub_10034680 同款机制）。
pub fn candidates(src: &InquirySources) -> Vec<String> {
    let mut cs: Vec<String> = Vec::new();
    let add = |c: String, cs: &mut Vec<String>| {
        if !c.is_empty() && !cs.contains(&c) {
            cs.push(c);
        }
    };
    if let Some((v, p, rev)) = &src.inquiry {
        let long_id = build_device_id(v, p, rev, Transport::Bot);
        let short_id = build_device_id(v, p, rev, Transport::Uas);
        if src.transport == Transport::Uas {
            add(short_id, &mut cs);
            add(long_id, &mut cs);
        } else {
            add(long_id, &mut cs);
            add(short_id, &mut cs);
        }
    }
    if let Some((v, p)) = &src.usb_desc {
        add(build_device_id(v, p, "", Transport::Uas), &mut cs);
    }
    if let Some(media) = &src.media_name {
        add(format!("disk&ven_&prod_{}", norm(media)), &mut cs);
    }
    cs
}

#[cfg(test)]
mod tests {
    use super::*;

    /// disk5 真实盘的三候选回归（ioreg 实测顺序）。
    #[test]
    fn disk5_candidates() {
        let src = InquirySources {
            inquiry: Some(("SanDisk".into(), "Ultra USB 3.0".into(), "1.00".into())),
            transport: Transport::Bot,
            usb_desc: None,
            media_name: None,
        };
        assert_eq!(
            candidates(&src),
            vec![
                "disk&ven_sandisk&prod_ultra_usb_3.0&rev_1.00".to_string(),
                "disk&ven_sandisk&prod_ultra_usb_3.0".to_string(),
            ]
        );
    }

    #[test]
    fn norm_keeps_double_underscore() {
        // 中间连续空格 → 连续下划线（不合并）；尾部空格被 rstrip 去除
        assert_eq!(norm("A  B"), "a__b");
        assert_eq!(norm("Ultra USB 3.0  "), "ultra_usb_3.0");
        assert_eq!(norm(""), "");
    }

    #[test]
    fn uas_order_short_first() {
        let src = InquirySources {
            inquiry: Some(("LEXAR".into(), "USB Flash Drive".into(), "1100".into())),
            transport: Transport::Uas,
            ..Default::default()
        };
        let cs = candidates(&src);
        assert_eq!(cs[0], "disk&ven_lexar&prod_usb_flash_drive");
        assert_eq!(cs[1], "disk&ven_lexar&prod_usb_flash_drive&rev_1100");
    }

    #[test]
    fn media_name_fallback() {
        let src = InquirySources {
            media_name: Some("Generic USB SD Reader".into()),
            ..Default::default()
        };
        assert_eq!(
            candidates(&src),
            vec!["disk&ven_&prod_generic_usb_sd_reader"]
        );
    }
}
