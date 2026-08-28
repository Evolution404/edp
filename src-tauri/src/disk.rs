//! disk.rs — 盘枚举(diskutil plist) / ioreg INQUIRY / device_id 识别 / 扇区读。
//! raw 权限: 可直接打开时零授权；受保护时通过 macOS authopen 获取授权 FD。

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};

use crate::crypto::{a6b0_full, crc32_bare, xor_rolling};

pub const SECTOR: usize = 512;

#[derive(Debug, Clone, serde::Serialize)]
pub struct UsbDisk {
    pub disk: u32,
    pub size_bytes: u64,
    pub vid: String,
    pub pid: String,
}

fn cmd_out(prog: &str, args: &[&str]) -> Option<String> {
    let path = match prog {
        "diskutil" => "/usr/sbin/diskutil",
        "ioreg" => "/usr/sbin/ioreg",
        _ => prog,
    };
    Command::new(path)
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
    let Some(out) = cmd_out("ioreg", &["-r", "-c", cls, "-l"]) else { return Vec::new() };
    // `ioreg -r -c <Class>` 的顶层服务名不保证等于 Class，例如
    // `IOUSBHostDevice` 常显示为 `+-o USB Flash Drive@... <class IOUSBHostDevice,...>`。
    // 只按“第 0 列的 +-o”切根节点，避免把子节点误切开，同时兼容多盘同插。
    let Ok(root) = regex::Regex::new(r"(?m)^\+-o ") else { return Vec::new() };
    let starts: Vec<usize> = root.find_iter(&out).map(|m| m.start()).collect();
    if starts.is_empty() { return Vec::new(); }
    starts.iter().enumerate().map(|(i, &start)| {
        let end = starts.get(i + 1).copied().unwrap_or(out.len());
        out[start..end].to_string()
    }).collect()
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

fn usb_serial(disk: u32) -> Option<String> {
    let b = block_for_disk("IOUSBHostDevice", disk)?;
    for key in ["USB Serial Number", "kUSBSerialNumberString"] {
        let re = regex::Regex::new(&format!(r#""{key}"\s*=\s*"([^"]+)""#)).ok()?;
        if let Some(c) = re.captures(&b) {
            return Some(c.get(1)?.as_str().to_string());
        }
    }
    None
}

fn norm(s: &str) -> String {
    s.trim_end_matches(' ').replace(' ', "_").to_lowercase()
}

/// SCSI INQUIRY 三字段
fn inquiry(disk: u32) -> Option<(String, String, String)> {
    for cls in ["IOSCSITargetDevice", "IOSCSILogicalUnitNub", "IOSCSIPeripheralDeviceNub"] {
        let Some(b) = block_for_disk(cls, disk) else { continue };
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
fn read_lba_direct(disk: u32, lba: u64) -> std::io::Result<Vec<u8>> {
    let mut f = File::open(format!("/dev/rdisk{disk}"))?;
    f.seek(SeekFrom::Start(lba * SECTOR as u64))?;
    let mut buf = vec![0u8; SECTOR];
    f.read_exact(&mut buf)?;
    Ok(buf)
}

static META_CACHE: OnceLock<Mutex<HashMap<String, Vec<u8>>>> = OnceLock::new();

fn metadata_cache_key(disk: u32) -> Option<String> {
    Some(format!(
        "{disk}:{}:{}",
        disk_size_bytes(disk)?,
        usb_serial(disk)?
    ))
}

/// 通过 macOS authopen 获取已授权的 raw-device FD。
/// `write=false` 请求 O_RDONLY；`write=true` 请求 O_RDWR。
/// authopen 使用 SCM_RIGHTS 把已打开的 FD 交给父进程，父进程随后直接 seek/read/write。
pub(crate) fn authopen_rdisk(disk: u32, write: bool) -> std::io::Result<File> {
    if disk < 2 || !list_usb_disks().iter().any(|d| d.disk == disk) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "只允许访问 disk2+ 的外置 USB 整盘",
        ));
    }

    let path = format!("/dev/rdisk{disk}");
    let (parent_sock, child_sock) = UnixStream::pair()?;
    let child_stdout = unsafe { Stdio::from_raw_fd(child_sock.into_raw_fd()) };
    let flags = if write { libc::O_RDWR } else { libc::O_RDONLY };
    let mut child = Command::new("/usr/libexec/authopen")
        .args(["-stdoutpipe", "-o", &flags.to_string(), &path])
        .stdout(child_stdout)
        .stderr(Stdio::piped())
        .spawn()?;

    let mut data = [0u8; 16];
    let mut iov = libc::iovec {
        iov_base: data.as_mut_ptr().cast(),
        iov_len: data.len(),
    };
    let mut control = [0u8; 128];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = control.len() as _;

    let received = unsafe { libc::recvmsg(parent_sock.as_raw_fd(), &mut msg, 0) };
    let status = child.wait()?;
    let mut stderr = String::new();
    if let Some(mut e) = child.stderr.take() { let _ = e.read_to_string(&mut stderr); }

    if received <= 0 || !status.success() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            if stderr.trim().is_empty() {
                format!("authopen {} 授权失败", if write { "读写" } else { "只读" })
            } else {
                stderr.trim().to_string()
            },
        ));
    }

    let cmsg = unsafe { libc::CMSG_FIRSTHDR(&msg) };
    if cmsg.is_null()
        || unsafe { (*cmsg).cmsg_level } != libc::SOL_SOCKET
        || unsafe { (*cmsg).cmsg_type } != libc::SCM_RIGHTS
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "authopen 未返回 SCM_RIGHTS 文件描述符",
        ));
    }
    let fd = unsafe { *(libc::CMSG_DATA(cmsg).cast::<libc::c_int>()) };
    if fd < 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "authopen 返回无效文件描述符",
        ));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn authorized_metadata(disk: u32) -> std::io::Result<Vec<u8>> {
    let key = metadata_cache_key(disk);
    let cache = META_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(k) = key.as_ref() {
        if let Some(v) = cache.lock().ok().and_then(|m| m.get(k).cloned()) {
            return Ok(v);
        }
    }

    let mut f = authopen_rdisk(disk, false)?;
    let mut data = vec![0u8; SECTOR * 14];
    f.seek(SeekFrom::Start(0))?;
    f.read_exact(&mut data)?;
    if let (Some(k), Ok(mut m)) = (key, cache.lock()) { m.insert(k, data.clone()); }
    Ok(data)
}

pub fn read_lba(disk: u32, lba: u64) -> std::io::Result<Vec<u8>> {
    match read_lba_direct(disk, lba) {
        Ok(v) => Ok(v),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied && lba < 14 => {
            let all = authorized_metadata(disk)?;
            let off = lba as usize * SECTOR;
            Ok(all[off..off + SECTOR].to_vec())
        }
        Err(e) => Err(e),
    }
}

fn disk_size_bytes(disk: u32) -> Option<u64> {
    let name = format!("disk{disk}");
    let info = cmd_out("diskutil", &["info", "-plist", &name])?;
    let pl = plist::Value::from_reader(std::io::Cursor::new(info.as_bytes())).ok()?;
    let d = pl.as_dictionary()?;
    d.get("TotalSize")
        .or_else(|| d.get("DiskSize"))
        .or_else(|| d.get("Size"))
        .and_then(|v| v.as_unsigned_integer())
}

fn recover_device_id_from_lba11(raw: &[u8], vid: &str, pid: &str, size: u64) -> Option<String> {
    if raw.len() != SECTOR || vid.len() != 4 || pid.len() != 4 || size == 0 { return None; }
    let rand = &raw[..0x100];
    let chs_unit = 255u64 * 63 * SECTOR as u64;
    let chs = (size / chs_unit) * chs_unit;
    let mut sizes = vec![size];
    if chs != 0 && chs != size { sizes.push(chs); }

    for sz in sizes {
        let mut seed = rand.to_vec();
        seed.extend_from_slice(vid.as_bytes());
        seed.extend_from_slice(pid.as_bytes());
        seed.extend_from_slice(&sz.to_le_bytes());
        let key = crc32_bare(&seed).to_le_bytes();
        let pt = a6b0_full(&raw[0x100..], &key, 0);
        if !pt.starts_with(b"PDKB") { continue; }
        let bytes = &pt[4..];
        let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
        let device_id = std::str::from_utf8(&bytes[..end]).ok()?.trim().to_string();
        if !device_id.is_empty() { return Some(device_id); }
    }
    None
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

/// 严格身份识别：保留底层读取/授权失败原因，供 CLI 与改造流程准确报错。
pub fn identify_checked(disk: u32) -> Result<Identity, String> {
    let raw7 = read_lba(disk, 7).map_err(|e| format!("读 LBA7 失败: {e}"))?;
    for c in generate_candidates(disk) {
        let crc = crc32_bare(c.as_bytes());
        let k0 = lba7_k0(crc);
        if xor_rolling(&raw7, k0).starts_with(b"EDPF") {
            return Ok(Identity { device_id: c, crc, k0 });
        }
    }

    let raw11 = read_lba(disk, 11).map_err(|e| format!("读 LBA11 失败: {e}"))?;
    let (vid, pid) = usb_vid_pid(disk).ok_or("无法从 ioreg 获取该盘 VID/PID")?;
    let size = disk_size_bytes(disk).ok_or("无法从 diskutil 获取该盘容量")?;
    let c = recover_device_id_from_lba11(&raw11, &vid, &pid, size)
        .ok_or("SCSI INQUIRY 两候选均失败，且 LBA11 PDKB 未能恢复 device_id")?;
    let crc = crc32_bare(c.as_bytes());
    let k0 = lba7_k0(crc);
    if xor_rolling(&raw7, k0).starts_with(b"EDPF") {
        Ok(Identity { device_id: c, crc, k0 })
    } else {
        Err("LBA11 恢复出的 device_id 无法通过 LBA7 EDPF 二次验真".into())
    }
}

/// 宽松身份识别：扇区浏览等可选解密路径使用；失败时仅表示“当前不可解密”。
pub fn identify(disk: u32) -> Option<Identity> {
    identify_checked(disk).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::a7f0_full;

    #[test]
    fn ioreg_root_split_handles_named_usb_service() {
        let fixture = concat!(
            "+-o USB Flash Drive@00100000  <class IOUSBHostDevice, id 0x1>\n",
            "  |   \"idVendor\" = 8644\n",
            "  |   +-o Media <class IOMedia>\n",
            "  |       \"BSD Name\" = \"disk4\"\n",
            "+-o Other Device@00200000  <class IOUSBHostDevice, id 0x2>\n",
            "  |   \"idVendor\" = 1234\n",
            "  |   +-o Media <class IOMedia>\n",
            "  |       \"BSD Name\" = \"disk5\"\n",
        );
        let root = regex::Regex::new(r"(?m)^\+-o ").unwrap();
        let starts: Vec<usize> = root.find_iter(fixture).map(|m| m.start()).collect();
        assert_eq!(starts.len(), 2);
        let first = &fixture[starts[0]..starts[1]];
        assert!(first.contains("\"BSD Name\" = \"disk4\""));
        assert!(!first.contains("disk5"));
    }

    #[test]
    fn lba11_recovers_embedded_device_id() {
        let vid = "21c4";
        let pid = "0cd1";
        let size = 124_736_503_808u64;
        let device_id = "disk&ven_lexar&prod_usb_flash_drive&rev_1100";
        let mut raw = vec![0u8; SECTOR];
        for (i, b) in raw[..0x100].iter_mut().enumerate() { *b = (i as u8).wrapping_mul(17); }
        let mut pt = vec![0u8; 0x100];
        pt[..4].copy_from_slice(b"PDKB");
        pt[4..4 + device_id.len()].copy_from_slice(device_id.as_bytes());
        let mut seed = raw[..0x100].to_vec();
        seed.extend_from_slice(vid.as_bytes());
        seed.extend_from_slice(pid.as_bytes());
        seed.extend_from_slice(&size.to_le_bytes());
        let key = crc32_bare(&seed).to_le_bytes();
        raw[0x100..].copy_from_slice(&a7f0_full(&pt, &key, 0));
        assert_eq!(recover_device_id_from_lba11(&raw, vid, pid, size).as_deref(), Some(device_id));
    }
}
