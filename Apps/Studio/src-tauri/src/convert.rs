//! convert.rs — 免密改造 5 扇生成, 与 nopwd.py 逐字节一致(golden 对拍)。
//! 三条铁律: EDPF 表尾终止符保留; LBA12 尾 144B 保留; 不发明原盘没有的状态。

use crate::{crypto, disk, parser};

pub use edpopen_core::convert::{convert, ConvertPlan, E12, E7, NOPWD_LBA6_1CA, PWD_CRC};
const EDPF_ENC_LEN: usize = 368;

// ══════════════════════════════════════════════════════════════════════════
// 授权写入器: 身份复核 → 卸载 → authopen O_RDWR → 备份 → 写序铁律 → 回读校验
// ══════════════════════════════════════════════════════════════════════════
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// 写入器允许的 LBA 白名单(仅元数据区, 限制破坏面)
pub const WRITABLE_LBAS: &[u64] = &[0, 4, 6, 7, 8, 9, 11, 12, 13];

#[derive(serde::Deserialize)]
pub struct WritePayload {
    pub disk: u32,
    pub backup_dir: String,
    pub device_id: String,
    #[serde(default)]
    pub lid: Option<u64>,
    #[serde(default)]
    pub vid: String,
    #[serde(default)]
    pub pid: String,
    #[serde(default)]
    pub total_sectors: Option<u64>,
    #[serde(default)]
    pub allow_nopwd: bool,              // 字节编辑可允许 NoPwd；免密改造本身保持 false
    pub uid: u32,                       // 备份文件 chown 回该用户
    pub sectors: std::collections::BTreeMap<String, String>, // lba → hex(512B)
}

#[derive(serde::Serialize)]
pub struct WriteResult {
    pub ok: bool,
    pub backup_path: Option<String>,
    pub written: Vec<u64>,
    pub verified: Vec<u64>,
    pub error: Option<String>,
}

#[derive(serde::Serialize)]
pub struct BackupRecord {
    pub file_name: String,
    pub path: String,
    pub size_bytes: u64,
    pub lid: Option<u64>,
    pub md5_ok: bool,
    pub current_match: bool,
}

fn backup_md5_path(path: &Path) -> PathBuf {
    path.with_extension("bin.md5")
}

fn backup_lid(data: &[u8]) -> Option<u64> {
    if data.len() != 14 * 512 { return None; }
    crypto::lba4_parse_serial(&data[4 * 512..5 * 512])
}

fn backup_md5_ok(path: &Path, data: &[u8]) -> bool {
    let expected = match fs::read_to_string(backup_md5_path(path)) {
        Ok(s) => s.split_whitespace().next().unwrap_or("").to_ascii_lowercase(),
        Err(_) => return false,
    };
    !expected.is_empty() && expected == format!("{:x}", md5::compute(data))
}

fn load_backup(path: &Path) -> Result<Vec<u8>, String> {
    let data = fs::read(path).map_err(|e| format!("读取备份 {}: {e}", path.display()))?;
    if data.len() != 14 * 512 {
        return Err(format!("备份大小异常: 应为 {}B, 实际 {}B", 14 * 512, data.len()));
    }
    if !backup_md5_ok(path, &data) {
        return Err("备份 MD5 缺失或校验失败".into());
    }
    Ok(data)
}

fn canonical_backup_path(backup_dir: &Path, requested: &Path) -> Result<PathBuf, String> {
    let root = backup_dir.canonicalize().map_err(|e| format!("备份目录不可用: {e}"))?;
    let path = requested.canonicalize().map_err(|e| format!("备份文件不可用: {e}"))?;
    if !path.starts_with(&root) || path.extension().and_then(|s| s.to_str()) != Some("bin") {
        return Err("拒绝访问备份目录之外的文件".into());
    }
    Ok(path)
}

pub fn list_backup_records(backup_dir: &Path, current_lid: Option<u64>) -> Result<Vec<BackupRecord>, String> {
    if !backup_dir.exists() { return Ok(Vec::new()); }
    let mut rows = Vec::new();
    for entry in fs::read_dir(backup_dir).map_err(|e| format!("读取备份目录: {e}"))? {
        let entry = entry.map_err(|e| format!("读取备份项: {e}"))?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("bin") { continue; }
        let data = match fs::read(&path) {
            Ok(d) => d,
            Err(_) => continue,
        };
        let lid = backup_lid(&data);
        let md5_ok = data.len() == 14 * 512 && backup_md5_ok(&path, &data);
        rows.push(BackupRecord {
            file_name: path.file_name().and_then(|s| s.to_str()).unwrap_or_default().to_string(),
            path: path.to_string_lossy().into_owned(),
            size_bytes: data.len() as u64,
            lid,
            md5_ok,
            current_match: md5_ok && lid.is_some() && lid == current_lid,
        });
    }
    rows.sort_by(|a, b| b.file_name.cmp(&a.file_name));
    Ok(rows)
}

fn disk_status_from_metadata(raw0: &[u8], raw9: &[u8], raw12: &[u8], crc: u32) -> Result<parser::DiskStatus, String> {
    if raw0.len() != 512 || raw9.len() != 512 || raw12.len() != 512 {
        return Err("元数据扇区长度异常".into());
    }
    let dec12 = crypto::a6b0_full(&raw12[..EDPF_ENC_LEN], &crc.to_le_bytes(), 0);
    if !dec12.starts_with(b"EDPF") { return Err("LBA12 非 EDPF".into()); }
    let entries = parser::parse_edpf(&dec12, E12);
    let mbr = parser::parse_mbr(raw0).unwrap_or_default();
    Ok(parser::classify(&entries, &mbr, raw9.iter().any(|&b| b != 0)))
}

fn validate_restore_source(data: &[u8], id: &disk::Identity, current_lid: u64) -> Result<(), String> {
    if data.len() != 14 * 512 { return Err("备份长度不是 LBA0-13".into()); }
    let lid = backup_lid(data).ok_or("备份 LBA4 唯一 ID 无法解析")?;
    if lid != current_lid {
        return Err(format!("备份属于另一只盘: LBA4 唯一 ID {lid}, 当前 {current_lid}"));
    }

    let raw7 = &data[7 * 512..8 * 512];
    if !crypto::xor_rolling(raw7, id.k0).starts_with(b"EDPF") {
        return Err("备份 LBA7 无法用备份自身 device_id 解出 EDPF".into());
    }
    let status = disk_status_from_metadata(
        &data[0..512],
        &data[9 * 512..10 * 512],
        &data[12 * 512..13 * 512],
        id.crc,
    )?;
    if status != parser::DiskStatus::Encrypted {
        return Err("只允许还原标准加密盘状态的备份".into());
    }
    Ok(())
}

fn identity_from_backup(data: &[u8], vid: &str, pid: &str, size_bytes: u64) -> Result<disk::Identity, String> {
    if data.len() != 14 * 512 { return Err("备份长度不是 LBA0-13".into()); }
    let raw11 = &data[11 * 512..12 * 512];
    let device_id = disk::recover_device_id_from_lba11(raw11, vid, pid, size_bytes)
        .ok_or("无法从备份 LBA11 恢复 device_id")?;
    let crc = crypto::crc32_bare(device_id.as_bytes());
    let k0 = disk::lba7_k0(crc);
    let raw7 = &data[7 * 512..8 * 512];
    if !crypto::xor_rolling(raw7, k0).starts_with(b"EDPF") {
        return Err("备份 LBA11 恢复的 device_id 无法通过备份 LBA7 二次验真".into());
    }
    Ok(disk::Identity { device_id, crc, k0 })
}

fn decode_sector_hex(lba: u64, s: &str) -> Result<Vec<u8>, String> {
    if s.len() != 1024 { return Err(format!("LBA{lba} 数据非 512B")); }
    (0..512)
        .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16)
            .map_err(|_| format!("LBA{lba} 含非法十六进制数据")))
        .collect()
}

fn validate_write_status(status: parser::DiskStatus, allow_nopwd: bool) -> Result<(), String> {
    match status {
        parser::DiskStatus::Encrypted => Ok(()),
        parser::DiskStatus::NoPwd if allow_nopwd => Ok(()),
        parser::DiskStatus::NoPwd => Err("目标盘已是免密盘，本次写入类型不允许 NoPwd 状态".into()),
        parser::DiskStatus::NotCems => Err("目标盘结构无法识别，拒绝写入".into()),
    }
}

fn validate_target(p: &WritePayload) -> Result<(), String> {
    if p.disk < 2 { return Err("拒绝系统盘".into()); }
    let usb = disk::list_usb_disks().into_iter().find(|d| d.disk == p.disk)
        .ok_or_else(|| format!("disk{} 已不存在或不是外置 USB 整盘", p.disk))?;
    if !p.vid.is_empty() && p.vid != "0000" && !usb.vid.eq_ignore_ascii_case(&p.vid) {
        return Err(format!("目标盘 VID 已变化: 预期 {}, 当前 {}", p.vid, usb.vid));
    }
    if !p.pid.is_empty() && p.pid != "0000" && !usb.pid.eq_ignore_ascii_case(&p.pid) {
        return Err(format!("目标盘 PID 已变化: 预期 {}, 当前 {}", p.pid, usb.pid));
    }
    if let Some(expect) = p.total_sectors {
        let actual = usb.size_bytes / 512;
        if actual != expect {
            return Err(format!("目标盘容量已变化: 预期 {expect} 扇, 当前 {actual} 扇"));
        }
    }

    let id = disk::identify_checked(p.disk)?;
    if id.device_id != p.device_id {
        return Err(format!("目标盘 device_id 已变化: 预期 {}, 当前 {}", p.device_id, id.device_id));
    }
    if let Some(expect) = p.lid {
        let raw4 = disk::read_lba(p.disk, 4).map_err(|e| format!("复核 LBA4 失败: {e}"))?;
        let actual = crypto::lba4_parse_serial(&raw4)
            .ok_or("复核 LBA4 唯一 ID 失败")?;
        if actual != expect {
            return Err(format!("目标盘 LBA4 唯一 ID 已变化: 预期 {expect}, 当前 {actual}"));
        }
    }

    let raw12 = disk::read_lba(p.disk, 12).map_err(|e| format!("复核 LBA12 失败: {e}"))?;
    let dec12 = crypto::a6b0_full(&raw12[..EDPF_ENC_LEN], &id.crc.to_le_bytes(), 0);
    if !dec12.starts_with(b"EDPF") { return Err("复核 LBA12 非 EDPF".into()); }
    let entries = parser::parse_edpf(&dec12, E12);
    let raw0 = disk::read_lba(p.disk, 0).map_err(|e| format!("复核 LBA0 失败: {e}"))?;
    let mbr = parser::parse_mbr(&raw0).unwrap_or_default();
    let raw9 = disk::read_lba(p.disk, 9).map_err(|e| format!("复核 LBA9 失败: {e}"))?;
    let status = parser::classify(&entries, &mbr, raw9.iter().any(|&b| b != 0));
    validate_write_status(status, p.allow_nopwd)

}

fn diskutil(disk: u32, action: &str) -> Result<(), String> {
    let name = format!("disk{disk}");
    let out = std::process::Command::new("/usr/sbin/diskutil")
        .args([action, "force", &name])
        .output()
        .map_err(|e| format!("diskutil {action}: {e}"))?;
    if out.status.success() { return Ok(()); }
    let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
    Err(if err.is_empty() { format!("diskutil {action} 失败") } else { err })
}

fn remount_disk(disk: u32) {
    let name = format!("disk{disk}");
    let _ = std::process::Command::new("/usr/sbin/diskutil")
        .args(["mountDisk", &name])
        .output();
}

fn read_metadata_backup(f: &mut File) -> Result<Vec<u8>, String> {
    f.seek(SeekFrom::Start(0)).map_err(|e| format!("备份 seek: {e}"))?;
    let mut backup = vec![0u8; 14 * 512];
    f.read_exact(&mut backup).map_err(|e| format!("备份读 LBA0-13: {e}"))?;
    Ok(backup)
}

fn write_order(decoded: &std::collections::BTreeMap<u64, Vec<u8>>) -> Vec<u64> {
    let mut order: Vec<u64> = decoded.keys().copied().filter(|&l| l != 0).collect();
    if decoded.contains_key(&0) { order.push(0); }
    order
}

fn write_and_verify_fd(
    f: &mut File,
    decoded: &std::collections::BTreeMap<u64, Vec<u8>>,
    wrote_any: &mut bool,
) -> Result<(Vec<u64>, Vec<u64>), String> {
    let order = write_order(decoded);
    let mut written = Vec::new();
    for &lba in &order {
        let data = &decoded[&lba];
        f.seek(SeekFrom::Start(lba * 512)).map_err(|e| format!("seek LBA{lba}: {e}"))?;
        f.write_all(data).map_err(|e| format!("写 LBA{lba}: {e}"))?;
        *wrote_any = true;
        written.push(lba);
    }
    f.sync_all().map_err(|e| format!("sync: {e}"))?;

    let mut verified = Vec::new();
    let mut one = [0u8; 512];
    for &lba in &order {
        f.seek(SeekFrom::Start(lba * 512)).map_err(|e| format!("校验 seek LBA{lba}: {e}"))?;
        f.read_exact(&mut one).map_err(|e| format!("回读 LBA{lba}: {e}"))?;
        if one[..] != decoded[&lba][..] {
            return Err(format!("LBA{lba} 回读不一致"));
        }
        verified.push(lba);
    }
    Ok((written, verified))
}

/// 已构造 payload 的正式写入入口。授权由 authopen O_RDWR 提供，不再依赖 root direct-open。
pub fn write_sectors(p: WritePayload) -> Result<WriteResult, String> {
    let mut lbas = Vec::new();
    let mut decoded = std::collections::BTreeMap::<u64, Vec<u8>>::new();
    for (k, v) in &p.sectors {
        let lba: u64 = k.parse().map_err(|_| format!("非法 LBA 键 {k}"))?;
        if !WRITABLE_LBAS.contains(&lba) { return Err(format!("LBA{lba} 不在白名单 {WRITABLE_LBAS:?}")); }
        decoded.insert(lba, decode_sector_hex(lba, v)?);
        lbas.push(lba);
    }
    if lbas.is_empty() { return Err("无写入扇区".into()); }
    validate_target(&p)?;

    fs::create_dir_all(&p.backup_dir).map_err(|e| format!("建备份目录: {e}"))?;
    let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let now = chrono_like(ts);
    let lid_part = p.lid.map(|l| format!("_lid{l}")).unwrap_or_default();
    let secs_part = p.total_sectors.map(|s| format!("{s}")).unwrap_or_else(|| "unknown".into());
    let backup_path: PathBuf = Path::new(&p.backup_dir).join(
        format!("disk{}_{}_vid{}_pid{}_{}{}{}_{}.bin",
                p.disk, secs_part, p.vid, p.pid, p.device_id, "", lid_part, now));

    // O_RDWR authopen 在卷仍挂载时会被系统拒绝；先卸载，再只申请一次读写 FD。
    diskutil(p.disk, "unmountDisk")?;
    let mut wrote_any = false;
    let operation = (|| -> Result<WriteResult, String> {
        let mut f = disk::authopen_rdisk(p.disk, true)
            .map_err(|e| format!("authopen 读写授权失败: {e}"))?;

        // 1. 同一个已授权 FD 先完整备份 LBA0-13；备份成功前绝不写盘。
        let backup = read_metadata_backup(&mut f)?;
        fs::write(&backup_path, &backup).map_err(|e| format!("写备份: {e}"))?;
        let digest = format!("{:x}", md5::compute(&backup));
        fs::write(backup_path.with_extension("bin.md5"), format!("{digest}\n"))
            .map_err(|e| format!("写 md5: {e}"))?;
        chown_user(&backup_path, p.uid);
        chown_user(&backup_path.with_extension("bin.md5"), p.uid);

        // 2/3. LBA0 永远最后写；sync 后不 reopen，继续使用同一授权 FD 回读。
        let (written, verified) = write_and_verify_fd(&mut f, &decoded, &mut wrote_any)?;
        Ok(WriteResult {
            ok: true,
            backup_path: Some(backup_path.to_string_lossy().into_owned()),
            written,
            verified,
            error: None,
        })
    })();

    // 成功时主动恢复挂载；授权取消/备份失败且尚未写任何扇区时也恢复。
    // 若已发生部分写入后失败，则保持卸载，避免自动挂载不完整状态。
    if operation.is_ok() || !wrote_any { remount_disk(p.disk); }
    operation
}

pub fn restore_backup(
    disk_no: u32,
    backup_dir: &Path,
    requested_path: &Path,
    uid: u32,
) -> Result<WriteResult, String> {
    if disk_no < 2 { return Err("拒绝系统盘".into()); }
    let source_path = canonical_backup_path(backup_dir, requested_path)?;
    let source = load_backup(&source_path)?;

    let usb = disk::list_usb_disks().into_iter().find(|d| d.disk == disk_no)
        .ok_or_else(|| format!("disk{disk_no} 已不存在或不是外置 USB 整盘"))?;
    // 还原身份从“已校验的来源备份”恢复，而不是依赖当前 LBA7/LBA12。
    // 这样即使字节编辑把当前结构改坏，只要 LBA4 唯一 ID 仍匹配，仍可安全恢复。
    let id = identity_from_backup(&source, &usb.vid, &usb.pid, usb.size_bytes)?;
    let raw4 = disk::read_lba(disk_no, 4).map_err(|e| format!("读取当前 LBA4: {e}"))?;
    let current_lid = crypto::lba4_parse_serial(&raw4).ok_or("当前 LBA4 唯一 ID 无法解析")?;
    validate_restore_source(&source, &id, current_lid)?;

    let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let safety_path = backup_dir.join(format!(
        "prerestore_disk{}_{}_vid{}_pid{}_{}_lid{}_{}.bin",
        disk_no,
        usb.size_bytes / 512,
        usb.vid,
        usb.pid,
        id.device_id,
        current_lid,
        chrono_like(ts),
    ));

    let mut decoded = std::collections::BTreeMap::<u64, Vec<u8>>::new();
    for lba in [0u64, 6, 7, 9, 12] {
        let off = lba as usize * 512;
        decoded.insert(lba, source[off..off + 512].to_vec());
    }

    diskutil(disk_no, "unmountDisk")?;
    let mut wrote_any = false;
    let operation = (|| -> Result<WriteResult, String> {
        let mut f = disk::authopen_rdisk(disk_no, true)
            .map_err(|e| format!("authopen 读写授权失败: {e}"))?;

        // 还原前再次完整保存“当前状态”，因此还原动作本身也可逆。
        let current_backup = read_metadata_backup(&mut f)?;
        fs::write(&safety_path, &current_backup).map_err(|e| format!("写还原前安全备份: {e}"))?;
        let digest = format!("{:x}", md5::compute(&current_backup));
        fs::write(backup_md5_path(&safety_path), format!("{digest}\n"))
            .map_err(|e| format!("写还原前安全备份 MD5: {e}"))?;
        chown_user(&safety_path, uid);
        chown_user(&backup_md5_path(&safety_path), uid);

        let (written, verified) = write_and_verify_fd(&mut f, &decoded, &mut wrote_any)?;
        Ok(WriteResult {
            ok: true,
            backup_path: Some(safety_path.to_string_lossy().into_owned()),
            written,
            verified,
            error: None,
        })
    })();

    if operation.is_ok() || !wrote_any { remount_disk(disk_no); }
    operation
}

/// CLI 兼容入口：读取 JSON payload，调用同一 authopen 写入核心并写 result.json。
pub fn write_sectors_run(payload_path: &Path, result_path: &Path) -> i32 {
    let parsed: Result<WritePayload, String> = File::open(payload_path)
        .map_err(|e| format!("打开 payload: {e}"))
        .and_then(|f| serde_json::from_reader(f).map_err(|e| format!("解析 payload: {e}")));
    let result = match parsed.and_then(write_sectors) {
        Ok(res) => res,
        Err(e) => WriteResult { ok: false, backup_path: None, written: vec![], verified: vec![], error: Some(e) },
    };
    let _ = fs::remove_file(payload_path);
    let code = if result.ok { 0 } else { 1 };
    let _ = fs::write(result_path, serde_json::to_string(&result).unwrap());
    code
}

/// 简易时间戳 YYYYmmdd_HHMMSS(UTC+8 近似, 仅用于文件名; 不引 chrono)
fn chrono_like(secs: u64) -> String {
    let days = secs / 86400;
    let (y, mo, d) = civil_from_days(days as i64);
    let rem = secs % 86400;
    format!("{y:04}{mo:02}{d:02}_{:02}{:02}{:02}", rem / 3600, rem % 3600 / 60, rem % 60)
}

fn civil_from_days(z: i64) -> (i64, u64, u64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(unix)]
fn chown_user(path: &Path, uid: u32) {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    unsafe { libc_chown(c.as_ptr(), uid, -1i32 as u32); }
}

#[cfg(unix)]
extern "C" {
    #[link_name = "chown"]
    fn libc_chown(path: *const std::os::raw::c_char, owner: u32, group: u32) -> i32;
}
#[cfg(not(unix))]
fn chown_user(_path: &Path, _uid: u32) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_status_gate_keeps_convert_strict_but_allows_nopwd_editor() {
        assert!(validate_write_status(parser::DiskStatus::Encrypted, false).is_ok());
        assert!(validate_write_status(parser::DiskStatus::Encrypted, true).is_ok());
        assert!(validate_write_status(parser::DiskStatus::NoPwd, false).is_err());
        assert!(validate_write_status(parser::DiskStatus::NoPwd, true).is_ok());
        assert!(validate_write_status(parser::DiskStatus::NotCems, true).is_err());
    }

    #[test]
    fn sector_hex_validation_is_strict() {
        let good = "00".repeat(512);
        assert_eq!(decode_sector_hex(7, &good).unwrap(), vec![0u8; 512]);
        assert!(decode_sector_hex(7, &"00".repeat(511)).is_err());
        let mut bad = good;
        bad.replace_range(10..12, "zz");
        assert!(decode_sector_hex(7, &bad).is_err());
    }

    #[test]
    fn backup_catalog_requires_md5_and_lid_match() {
        use std::fs::OpenOptions;

        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("edpopen-backups-{}-{unique}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("sample.bin");
        let data = vec![0u8; 14 * 512];
        std::fs::write(&path, &data).unwrap();
        std::fs::write(backup_md5_path(&path), format!("{:x}\n", md5::compute(&data))).unwrap();

        let rows = list_backup_records(&dir, Some(123)).unwrap();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].md5_ok);
        assert!(!rows[0].current_match);
        assert!(rows[0].lid.is_none());

        let outside = std::env::temp_dir().join(format!("edpopen-outside-{}-{unique}.bin", std::process::id()));
        OpenOptions::new().create_new(true).write(true).open(&outside).unwrap();
        assert!(canonical_backup_path(&dir, &outside).is_err());

        std::fs::remove_file(outside).unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn local_golden_backup_passes_restore_source_validation_when_available() {
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests");
        let Ok(vectors_text) = std::fs::read_to_string(root.join("vectors.json")) else { return; };
        let Ok(golden_text) = std::fs::read_to_string(root.join("convert_golden.json")) else { return; };
        let vectors: serde_json::Value = serde_json::from_str(&vectors_text).unwrap();
        let golden: serde_json::Value = serde_json::from_str(&golden_text).unwrap();
        let g = &golden["disks"][0];
        let name = g["name"].as_str().unwrap();
        let v = vectors["disks"].as_array().unwrap().iter()
            .find(|x| x["name"].as_str() == Some(name)).unwrap();
        let unhex = |s: &str| -> Vec<u8> {
            (0..s.len() / 2).map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap()).collect()
        };
        let mut backup = vec![0u8; 14 * 512];
        backup[0..512].copy_from_slice(&unhex(g["raw0"].as_str().unwrap()));
        for lba in [4usize, 6, 7, 9, 11, 12] {
            let raw = unhex(v["sectors"][lba.to_string()]["raw_hex"].as_str().unwrap());
            backup[lba * 512..(lba + 1) * 512].copy_from_slice(&raw);
        }
        let id = identity_from_backup(
            &backup,
            v["vid"].as_str().unwrap(),
            v["pid"].as_str().unwrap(),
            v["size_bytes"].as_u64().unwrap(),
        ).unwrap();
        assert_eq!(id.device_id, v["device_id"].as_str().unwrap());
        let lid = backup_lid(&backup).unwrap();
        validate_restore_source(&backup, &id, lid).unwrap();
    }

    #[test]
    fn fd_transaction_backs_up_writes_lba0_last_and_verifies() {
        use std::fs::OpenOptions;

        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("edpopen-fd-{}-{unique}.img", std::process::id()));
        let mut f = OpenOptions::new().create_new(true).read(true).write(true).open(&path).unwrap();

        let mut original = vec![0u8; 14 * 512];
        for lba in 0..14usize {
            original[lba * 512..(lba + 1) * 512].fill(lba as u8);
        }
        f.write_all(&original).unwrap();
        f.sync_all().unwrap();
        assert_eq!(read_metadata_backup(&mut f).unwrap(), original);

        let mut decoded = std::collections::BTreeMap::new();
        for (lba, byte) in [(0u64, 0xA0), (6, 0xA6), (7, 0xA7), (9, 0xA9), (12, 0xAC)] {
            decoded.insert(lba, vec![byte; 512]);
        }
        let mut wrote_any = false;
        let (written, verified) = write_and_verify_fd(&mut f, &decoded, &mut wrote_any).unwrap();
        assert!(wrote_any);
        assert_eq!(written, vec![6, 7, 9, 12, 0]);
        assert_eq!(verified, written);

        for (&lba, expect) in &decoded {
            let mut got = vec![0u8; 512];
            f.seek(SeekFrom::Start(lba * 512)).unwrap();
            f.read_exact(&mut got).unwrap();
            assert_eq!(&got, expect, "LBA{lba}");
        }
        drop(f);
        std::fs::remove_file(path).unwrap();
    }
}
