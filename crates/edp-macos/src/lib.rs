//! # edp-macos
//!
//! macOS 系统集成层：
//! - `diskutil`/`ioreg`/`hdiutil` 子进程封装（plist/文本解析）
//! - device_id 发现所需的系统参数（VID/PID、INQUIRY、传输模式）
//! - DiskArbitration 监听（M2）

#![cfg(target_os = "macos")]

pub mod ioreg;

use serde::Serialize;
use std::path::Path;

/// 磁盘摘要。
#[derive(Debug, Clone, Serialize)]
pub struct DiskInfo {
    pub bsd: String,
    pub rbsd: String,
    pub total_size: u64,
    pub media_name: String,
    pub removable: bool,
    pub ejectable: bool,
    pub whole: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mount_point: Option<String>,
}

/// `diskutil list -plist [external physical]` 解析。
pub fn list_disks(all: bool) -> std::io::Result<Vec<DiskInfo>> {
    let mut cmd = std::process::Command::new("diskutil");
    cmd.args(["list", "-plist"]);
    if !all {
        cmd.args(["external", "physical"]);
    }
    let out = cmd.output()?;
    if !out.status.success() {
        return Err(std::io::Error::other(format!(
            "diskutil list 失败: {}",
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    let v: plist::Value = plist::from_bytes(&out.stdout)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let mut disks = Vec::new();
    if let Some(arr) = v
        .as_dictionary()
        .and_then(|d| d.get("AllDisksAndPartitions"))
        .and_then(|x| x.as_array())
    {
        for d in arr {
            let dict = match d.as_dictionary() {
                Some(x) => x,
                None => continue,
            };
            let bsd = dict
                .get("DeviceIdentifier")
                .and_then(|x| x.as_string())
                .unwrap_or_default()
                .to_string();
            if bsd.is_empty() {
                continue;
            }
            disks.push(DiskInfo {
                rbsd: format!("/dev/r{bsd}"),
                mount_point: None,
                total_size: 0,
                media_name: String::new(),
                removable: true,
                ejectable: true,
                whole: true,
                bsd,
            });
        }
    }
    // 逐盘补全详情（外置物理盘数量少，开销可接受）
    for disk in disks.iter_mut() {
        if let Ok(info) = disk_info_full(&disk.bsd) {
            disk.total_size = info.0;
            disk.media_name = info.1;
            disk.mount_point = info.2;
        }
    }
    Ok(disks)
}

/// `diskutil info -plist` 的关键字段：(TotalSize, MediaName, MountPoint)。
fn disk_info_full(bsd: &str) -> std::io::Result<(u64, String, Option<String>)> {
    let out = std::process::Command::new("diskutil")
        .args(["info", "-plist"])
        .arg(bsd)
        .output()?;
    let v: plist::Value = plist::from_bytes(&out.stdout)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let d = v.as_dictionary();
    let size = d
        .and_then(|x| x.get("TotalSize"))
        .and_then(plist::Value::as_unsigned_integer)
        .unwrap_or(0);
    let name = d
        .and_then(|x| x.get("MediaName"))
        .and_then(plist::Value::as_string)
        .unwrap_or_default()
        .to_string();
    let mount = d
        .and_then(|x| x.get("MountPoint"))
        .and_then(plist::Value::as_string)
        .map(|s| s.to_string());
    Ok((size, name, mount))
}

/// 设备总容量（字节）。
pub fn disk_size(bsd: &str) -> std::io::Result<u64> {
    Ok(disk_info_full(bsd)?.0)
}

/// `diskutil unmountDisk`（挂载前清掉系统自动挂载的公共区）。
pub fn unmount_disk(bsd: &str) -> std::io::Result<()> {
    let out = std::process::Command::new("diskutil")
        .args(["unmountDisk"])
        .arg(bsd)
        .output()?;
    if !out.status.success() {
        return Err(std::io::Error::other(format!(
            "unmountDisk 失败: {}",
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    Ok(())
}

/// `diskutil mount`（挂载指定分区，返回挂载点）。
pub fn mount_partition(bsd: &str) -> std::io::Result<String> {
    let out = std::process::Command::new("diskutil")
        .args(["mount"])
        .arg(bsd)
        .output()?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() {
        return Err(std::io::Error::other(format!(
            "mount 失败: {}",
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    // 输出形如 "Volume XXX on /Volumes/XXX mounted"
    match stdout.split_once(" on ").map(|(_, rest)| rest.to_string()) {
        Some(rest) => {
            let mp = rest.split_whitespace().next().unwrap_or("").to_string();
            Ok(mp)
        }
        None => Ok(stdout),
    }
}

/// hdiutil attach 明文 raw 镜像（参数逐字沿用已验证链路，`-owners off` 必须保留）。
pub fn hdiutil_attach_raw(
    virtual_file: &Path,
    readonly: bool,
    mountpoint: Option<&Path>,
) -> std::io::Result<(Vec<String>, Vec<String>)> {
    let mut cmd = std::process::Command::new("hdiutil");
    cmd.args(["attach", "-plist", "-nobrowse", "-owners", "off"])
        .arg("-imagekey")
        .arg("diskimage-class=CRawDiskImage");
    if readonly {
        cmd.arg("-readonly");
    }
    if let Some(mp) = mountpoint {
        cmd.arg("-mountpoint").arg(mp);
    }
    cmd.arg(virtual_file);
    let out = cmd.output()?;
    if !out.status.success() {
        return Err(std::io::Error::other(format!(
            "hdiutil attach 失败: {}",
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    let v: plist::Value = plist::from_bytes(&out.stdout)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let mut devices = Vec::new();
    let mut mountpoints = Vec::new();
    if let Some(entries) = v
        .as_dictionary()
        .and_then(|d| d.get("system-entities"))
        .and_then(|x| x.as_array())
    {
        for e in entries {
            if let Some(dict) = e.as_dictionary() {
                if let Some(dev) = dict.get("dev-entry").and_then(|x| x.as_string()) {
                    devices.push(dev.to_string());
                }
                if let Some(mp) = dict.get("mount-point").and_then(|x| x.as_string()) {
                    mountpoints.push(mp.to_string());
                }
            }
        }
    }
    Ok((devices, mountpoints))
}

/// `hdiutil detach`（可选 -force）。
pub fn hdiutil_detach(bsd: &str, force: bool) -> std::io::Result<()> {
    let mut cmd = std::process::Command::new("hdiutil");
    cmd.arg("detach");
    if force {
        cmd.arg("-force");
    }
    cmd.arg(bsd);
    let out = cmd.output()?;
    if !out.status.success() {
        return Err(std::io::Error::other(format!(
            "hdiutil detach 失败: {}",
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    Ok(())
}

/// `/sbin/umount`（卸载 bridge 挂载点）。
pub fn umount_path(path: &Path) {
    let _ = std::process::Command::new("/sbin/umount")
        .arg(path)
        .output();
}

/// macFUSE 版本（未安装返回 None）。
pub fn macfuse_version() -> Option<String> {
    let plist_path = "/Library/Filesystems/macfuse.fs/Contents/Info.plist";
    let data = std::fs::read(plist_path).ok()?;
    let v = plist::from_bytes::<plist::Value>(&data).ok()?;
    v.as_dictionary()?
        .get("CFBundleShortVersionString")?
        .as_string()
        .map(|s| s.to_string())
}

/// LBA11 参数（vid, pid, size）：ioreg IOUSBHostDevice 绑定 + diskutil 容量。
pub fn lba11_params(disk_num: u32) -> Option<(String, String, u64)> {
    ioreg::lba11_params(disk_num)
}

/// 从设备路径组装 identify 候选来源（非 /dev 路径返回空）。
pub fn inquiry_sources(path: &Path) -> edp_core::device::InquirySources {
    let Some(n) = path
        .to_str()
        .and_then(|s| s.strip_prefix("/dev/rdisk"))
        .and_then(|s| s.parse::<u32>().ok())
    else {
        return edp_core::device::InquirySources::default();
    };
    ioreg::inquiry_sources(n)
}
