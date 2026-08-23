//! discover_volume 编排：三级 device_id 候选 → LBA12 解析 → 目标分区定位。
//!
//! 候选顺序（真实数据验证过必要性——disk5 走不到第 2 级，必须第 3 级兜底）：
//! 1. 调用方显式传入
//! 2. LBA11 PDKB 标准路径（VID/PID + 容量两候选）
//! 3. identify 候选（INQUIRY/USB 描述符/MediaName 构造的长短版）
//!
//! 每个候选用其 CRC32 派生 key 解 LBA12，EDPF magic 即判真。

use std::sync::Arc;

use crate::device::{candidates as identify_candidates, InquirySources};
use crate::lba11::device_id_from_lba11;
use crate::lba12::{decode_lba12, parse_lba12_entries, VolumeDescriptor};
use crate::volume::{EncryptedPartitionIO, RawIo};
use crate::{CoreError, SECTOR_SIZE};

/// device_id 发现提示（由系统层组装）。
#[derive(Debug, Clone, Default)]
pub struct DeviceIdHints {
    /// 调用方显式传入（`--device-id`）。
    pub explicit: Option<String>,
    /// LBA11 标准路径参数：(vid_hex, pid_hex, disk_size_bytes)。仅硬件盘可得。
    pub lba11_params: Option<(String, String, u64)>,
    /// identify 候选来源（INQUIRY/传输模式/USB 描述符/MediaName）。
    pub inquiry: InquirySources,
}

/// 生成去重后的 device_id 候选列表（按优先级）。
pub fn candidate_device_ids(io: &dyn RawIo, hints: &DeviceIdHints) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let push = |c: String, out: &mut Vec<String>| {
        if !c.is_empty() && !out.contains(&c) {
            out.push(c);
        }
    };
    if let Some(id) = &hints.explicit {
        push(id.clone(), &mut out);
    }
    if let Some((vid, pid, size)) = &hints.lba11_params {
        let mut raw = [0u8; 512];
        if io.pread_exact(11 * SECTOR_SIZE, &mut raw).is_ok() {
            if let Some(dev) = device_id_from_lba11(&raw, vid, pid, *size) {
                push(dev, &mut out);
            }
        }
    }
    for c in identify_candidates(&hints.inquiry) {
        push(c, &mut out);
    }
    out
}

/// 分区发现错误。
#[derive(Debug, thiserror::Error)]
pub enum DiscoverError {
    /// 无任何可用 device_id 候选。
    #[error("无法自动识别 device_id（镜像文件无法从 LBA11 解析 VID/PID）；请显式传 --device-id")]
    NoCandidates,
    /// 密码错误或无目标分区。
    #[error("密码错误，或不存在 type={0} 的可挂载分区")]
    PasswordOrTypeMismatch(u32),
    /// 密码正确但目标类型不存在。
    #[error("密码正确但不存在 type={0} 的挂载分区；该盘可用 type={1:?}")]
    TypeNotAvailable(u32, Vec<u32>),
    #[error(transparent)]
    Core(#[from] CoreError),
}

/// 发现目标数据分区，返回 (descriptor, 命中的 device_id)。
pub fn discover_volume(
    io: &dyn RawIo,
    hints: &DeviceIdHints,
    password: &str,
    want_type: u32,
) -> Result<(VolumeDescriptor, String), DiscoverError> {
    let mut raw = [0u8; 512];
    io.pread_exact(12 * SECTOR_SIZE, &mut raw)
        .map_err(CoreError::from)?;
    let ids = candidate_device_ids(io, hints);
    if ids.is_empty() {
        return Err(DiscoverError::NoCandidates);
    }
    let mut available: Vec<u32> = Vec::new();
    let io_size = io.size();
    for cand in &ids {
        let plain = decode_lba12(&raw, cand);
        let entries = match parse_lba12_entries(&plain, password.as_bytes()) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries {
            if !available.contains(&entry.partition_type) {
                available.push(entry.partition_type);
            }
            if entry.partition_type == want_type {
                // 镜像文件（非 /dev）做边界检查
                if entry.start_bytes() + entry.size_bytes > io_size {
                    return Err(CoreError::Parse("EDPF 分区范围超过镜像大小".into()).into());
                }
                return Ok((entry, cand.clone()));
            }
        }
    }
    if !available.is_empty() {
        Err(DiscoverError::TypeNotAvailable(want_type, available))
    } else {
        Err(DiscoverError::PasswordOrTypeMismatch(want_type))
    }
}

/// 便捷函数：发现并以只读打开卷，读取首扇区做文件系统签名闭环
/// （`EXFAT   ` / `NTFS    `）。
pub fn probe_boot_sector(
    io: Arc<dyn RawIo>,
    desc: VolumeDescriptor,
) -> Result<[u8; 512], CoreError> {
    let vol = EncryptedPartitionIO::open(io, desc, true)?;
    let mut boot = [0u8; 512];
    vol.read(0, &mut boot)?;
    Ok(boot)
}

/// 解密后的文件系统签名（boot 扇区 +3..+11）。
pub fn filesystem_magic(boot: &[u8; 512]) -> Option<&'static str> {
    match &boot[3..11] {
        b"EXFAT   " => Some("EXFAT"),
        b"NTFS    " => Some("NTFS"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 用真实盘黄金数据 + MemIo 走完整 discovery。
    #[test]
    fn golden_discovery_two_real_disks() {
        let disks: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../fixtures/golden/disks.json"
            ))
            .unwrap(),
        )
        .unwrap();
        for d in disks["disks"].as_array().unwrap() {
            let device_id = d["device_id"].as_str().unwrap();
            let cipher12 = hex::decode(d["lba12"]["cipher_hex"].as_str().unwrap()).unwrap();
            let cipher7 = hex::decode(d["lba7"]["cipher_hex"].as_str().unwrap()).unwrap();
            // 构造稀疏最小镜像：LBA7/LBA12 放密文，逻辑大小覆盖分区范围
            let mut img = vec![0u8; 13 * 512];
            img[7 * 512..8 * 512].copy_from_slice(&cipher7);
            img[12 * 512..13 * 512].copy_from_slice(&cipher12);
            let logical = d["entries"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| {
                    e["start_sector"].as_u64().unwrap() * 512 + e["size_bytes"].as_u64().unwrap()
                })
                .max()
                .unwrap();
            let io = crate::volume::test_util::MemIo::from_with_logical_size(img, logical);

            // 显式 device_id 候选 → 应找到 type=4
            let hints = DeviceIdHints {
                explicit: Some(device_id.to_string()),
                ..Default::default()
            };
            let (desc, hit) = discover_volume(&io, &hints, "0000aaaa", 4).expect("应发现 type=4");
            assert_eq!(hit, device_id);
            assert_eq!(
                desc.start_sector,
                d["entries"].as_array().unwrap()[2]["start_sector"]
                    .as_u64()
                    .unwrap()
            );
            assert!(desc.file_key.is_some());

            // 错误密码：所有受保护条目跳过 → PasswordOrTypeMismatch
            let e = discover_volume(&io, &hints, "631770", 4).unwrap_err();
            assert!(matches!(e, DiscoverError::PasswordOrTypeMismatch(4)));

            // type=2 也可发现（Share 分区）
            let (d2, _) = discover_volume(&io, &hints, "0000aaaa", 2).unwrap();
            assert_eq!(d2.partition_type, 2);
        }
    }
}
