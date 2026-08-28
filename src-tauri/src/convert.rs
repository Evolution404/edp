//! convert.rs — 免密改造 5 扇生成, 与 nopwd.py 逐字节一致(golden 对拍)。
//! 三条铁律: EDPF 表尾终止符保留; LBA12 尾 144B 保留; 不发明原盘没有的状态。

use crate::crypto;

pub const PWD_CRC: u32 = 0x0429735D;     // CRC32("0000aaaa")
pub const NOPWD_LBA6_1CA: u32 = 128_480; // A 盘实测模板值(语义未定案)
pub const E7: usize = 0x40;              // LBA7 entry 步长
pub const E12: usize = 0x60;             // LBA12 entry 步长
const EDPF_ENC_LEN: usize = 368;

#[derive(Debug)]
pub struct ConvertPlan {
    pub share: u64,           // 扇
    pub enc_start: u64,
    pub enc_size: u64,        // 字节
    pub lba0: Vec<u8>,
    pub lba6: Vec<u8>,
    pub lba7: Vec<u8>,
    pub lba12: Vec<u8>,
    pub lba9: Option<Vec<u8>>, // 原非零才写(全零扇)
}

fn u32le(d: &mut [u8], off: usize, v: u32) { d[off..off + 4].copy_from_slice(&v.to_le_bytes()); }
fn u64le(d: &mut [u8], off: usize, v: u64) { d[off..off + 8].copy_from_slice(&v.to_le_bytes()); }

/// 以原 type=4 entry 为壳, 改 9 处字段, 其余原样(entry0/1 材料天然成对)
fn make_entry(src_e: &[u8], ptype: u32, start: u64, size: u64) -> Vec<u8> {
    let mut e = src_e.to_vec();
    e[..4].copy_from_slice(b"EDPF");
    u32le(&mut e, 0x08, 2);             // 版本 2
    u32le(&mut e, 0x0C, ptype);
    u32le(&mut e, 0x10, 1);             // 激活=1
    u32le(&mut e, 0x14, 1);             // 加密使能=1
    u64le(&mut e, 0x18, start);
    u64le(&mut e, 0x20, 0x200);         // bps=512
    u64le(&mut e, 0x28, size);
    u32le(&mut e, 0x30, PWD_CRC);
    e
}

fn find_type_entry(dec: &[u8], stride: usize, ptype: u32) -> Option<usize> {
    (0..3).find(|&i| {
        let e = &dec[i * stride..];
        &e[..4] == b"EDPF" && u32::from_le_bytes(e[0x0C..0x10].try_into().unwrap()) == ptype
    })
}

fn convert_lba0(raw: &[u8], share: u64) -> Vec<u8> {
    let mut out = raw.to_vec();
    for i in 0..4 { out[0x1BE + i * 16..0x1BE + (i + 1) * 16].fill(0); }
    out[0x1BE + 4] = 0x07;
    out[0x1BE + 8..0x1BE + 12].copy_from_slice(&63u32.to_le_bytes());
    out[0x1BE + 12..0x1BE + 16].copy_from_slice(&(share as u32).to_le_bytes());
    out[0x1FE..0x200].copy_from_slice(b"\x55\xaa");
    out
}

fn convert_lba6(raw: &[u8]) -> Result<Vec<u8>, String> {
    let mut dec = crypto::lba6_decode(raw);
    if dec[0x188..0x190] == [0; 8] {
        return Err("LBA6 解密后 0x188 magic 为零 — 非法 SAFE6".into());
    }
    u32le(&mut dec, 0x1CA, NOPWD_LBA6_1CA);
    dec[0x1D4..0x1ED].fill(0);          // 清 25B(含 0x1EC)
    let cipher = crypto::xor_rolling(&dec[..0x1FC], crypto::LBA6_K0);
    let csum = crypto::lba6_checksum(&cipher);
    let mut out = cipher;
    out.extend_from_slice(&csum.to_le_bytes());
    if crypto::lba6_decode(&out)[..0x1FC] != dec[..0x1FC] {
        return Err("LBA6 往返自检失败".into());
    }
    Ok(out)
}

fn convert_lba7(raw: &[u8], k0: u16, share: u64) -> Result<Vec<u8>, String> {
    let mut dec = crypto::xor_rolling(raw, k0);
    if !dec.starts_with(b"EDPF") {
        return Err(format!("LBA7 解密后非 EDPF — device_id/K0 不符"));
    }
    let src = dec[find_type_entry(&dec, E7, 4).ok_or("LBA7 无 type=4 entry")? * E7..][..E7].to_vec();
    dec[..E7].copy_from_slice(&make_entry(&src, 2, 63, share * 512));
    let (s1, z1) = {
        let e1 = &dec[find_type_entry(&dec, E7, 4).ok_or("LBA7 type=4 消失")? * E7..];
        let s = u64::from_le_bytes(e1[0x18..0x20].try_into().unwrap());
        let z = u64::from_le_bytes(e1[0x28..0x30].try_into().unwrap());
        (s, z)
    };
    dec[E7..2 * E7].copy_from_slice(&make_entry(&src, 4, s1, z1));
    dec[2 * E7..3 * E7].fill(0);        // entry2 区清零(3→2 条); 0xC0 终止符不动
    Ok(crypto::xor_rolling(&dec, k0))
}

fn convert_lba12(raw: &[u8], crc_key: &[u8; 4], share: u64) -> Result<Vec<u8>, String> {
    let mut dec = crypto::a6b0_full(&raw[..EDPF_ENC_LEN], crc_key, 0);
    if !dec.starts_with(b"EDPF") {
        return Err("LBA12 解密后非 EDPF".into());
    }
    let src = dec[find_type_entry(&dec, E12, 4).ok_or("LBA12 无 type=4 entry")? * E12..][..E12].to_vec();
    dec[..E12].copy_from_slice(&make_entry(&src, 2, 63, share * 512));
    let (s1, z1) = {
        let s = u64::from_le_bytes(src[0x18..0x20].try_into().unwrap());
        let z = u64::from_le_bytes(src[0x28..0x30].try_into().unwrap());
        (s, z)
    };
    dec[E12..2 * E12].copy_from_slice(&make_entry(&src, 4, s1, z1));
    dec[2 * E12..3 * E12].fill(0);      // 0x120 终止符区与尾 144B 不动
    let mut out = crypto::a7f0_full(&dec, crc_key, 0);
    out.extend_from_slice(&raw[EDPF_ENC_LEN..]);   // 尾 144B 原密文
    if crypto::a6b0_full(&out[..EDPF_ENC_LEN], crc_key, 0) != dec {
        return Err("LBA12 往返自检失败".into());
    }
    Ok(out)
}

/// 5 扇改造。share=None 时默认 enc_start-63。
pub fn convert(
    raw0: &[u8], raw6: &[u8], raw7: &[u8], raw9: &[u8], raw12: &[u8],
    crc: u32, k0: u16, size_gb: Option<f64>,
) -> Result<ConvertPlan, String> {
    let crc_key = crc.to_le_bytes();
    let dec12 = crypto::a6b0_full(&raw12[..EDPF_ENC_LEN], &crc_key, 0);
    if !dec12.starts_with(b"EDPF") { return Err("LBA12 非 EDPF — 非可转换盘".into()); }
    let enc_idx = find_type_entry(&dec12, E12, 4).ok_or("LBA12 无 Encrypt entry")?;
    let enc_e = &dec12[enc_idx * E12..];
    let enc_start = u64::from_le_bytes(enc_e[0x18..0x20].try_into().unwrap());
    let enc_size = u64::from_le_bytes(enc_e[0x28..0x30].try_into().unwrap());
    let share = match size_gb {
        Some(gb) => ((gb * 1e9 / 512.0).round() as u64 / 8) * 8,
        None => enc_start - 63,
    };
    if 63 + share > enc_start {
        return Err(format!("Share@63+{share} 越过 Encrypt@{enc_start}"));
    }
    Ok(ConvertPlan {
        share, enc_start, enc_size,
        lba0: convert_lba0(raw0, share),
        lba6: convert_lba6(raw6)?,
        lba7: convert_lba7(raw7, k0, share)?,
        lba12: convert_lba12(raw12, &crc_key, share)?,
        lba9: if raw9.iter().any(|&b| b != 0) { Some(vec![0u8; 512]) } else { None },
    })
}

// ══════════════════════════════════════════════════════════════════════════
// 提权写入器(--write-sectors, 以 root 运行): 备份 → 写序铁律 → 回读校验
// ══════════════════════════════════════════════════════════════════════════
use std::fs::{self, File, OpenOptions};
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

fn rdisk(disk: u32, write: bool) -> std::io::Result<File> {
    // EBUSY 重试: 写 LBA0 改 MBR 会触发 macOS 重扫短暂锁盘(nopwd.py 实测教训)
    let mut last = None;
    for i in 0..15 {
        match OpenOptions::new().read(true).write(write).open(format!("/dev/rdisk{disk}")) {
            Ok(f) => return Ok(f),
            Err(e) if e.raw_os_error() == Some(16) && i < 14 => {
                last = Some(e);
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
            Err(e) => return Err(e),
        }
    }
    Err(last.unwrap())
}

/// 写入器主流程。返回 WriteResult 同时写入 result_path。
pub fn write_sectors_run(payload_path: &Path, result_path: &Path) -> i32 {
    let r = write_sectors_inner(payload_path);
    let result = match r {
        Ok(res) => res,
        Err(e) => WriteResult { ok: false, backup_path: None, written: vec![], verified: vec![], error: Some(e) },
    };
    let code = if result.ok { 0 } else { 1 };
    let _ = fs::write(result_path, serde_json::to_string(&result).unwrap());
    code
}

fn write_sectors_inner(payload_path: &Path) -> Result<WriteResult, String> {
    let p: WritePayload = serde_json::from_reader(
        File::open(payload_path).map_err(|e| format!("打开 payload: {e}"))?)
        .map_err(|e| format!("解析 payload: {e}"))?;
    if p.disk < 2 { return Err("拒绝系统盘".into()); }
    let mut lbas = Vec::new();
    for (k, v) in &p.sectors {
        let lba: u64 = k.parse().map_err(|_| format!("非法 LBA 键 {k}"))?;
        if !WRITABLE_LBAS.contains(&lba) { return Err(format!("LBA{lba} 不在白名单 {WRITABLE_LBAS:?}")); }
        if v.len() != 1024 { return Err(format!("LBA{lba} 数据非 512B")); }
        lbas.push(lba);
    }
    if lbas.is_empty() { return Err("无写入扇区".into()); }

    // ── 1. 备份 LBA0-13 ──
    fs::create_dir_all(&p.backup_dir).map_err(|e| format!("建备份目录: {e}"))?;
    let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let now = chrono_like(ts);
    let lid_part = p.lid.map(|l| format!("_lid{l}")).unwrap_or_default();
    let secs_part = p.total_sectors.map(|s| format!("{s}")).unwrap_or_else(|| "unknown".into());
    let backup_path: PathBuf = Path::new(&p.backup_dir).join(
        format!("disk{}_{}_vid{}_pid{}_{}{}{}_{}.bin",
                p.disk, secs_part, p.vid, p.pid, p.device_id, "", lid_part, now));
    {
        let mut f = rdisk(p.disk, false).map_err(|e| format!("打开盘(备份): {e}"))?;
        let mut data = Vec::with_capacity(14 * 512);
        let mut one = [0u8; 512];
        for lba in 0..14u64 {
            f.seek(SeekFrom::Start(lba * 512)).map_err(|e| format!("seek: {e}"))?;
            f.read_exact(&mut one).map_err(|e| format!("备份读 LBA{lba}: {e}"))?;
            data.extend_from_slice(&one);
        }
        fs::write(&backup_path, &data).map_err(|e| format!("写备份: {e}"))?;
        let digest = format!("{:x}", md5::compute(&data));
        fs::write(backup_path.with_extension("bin.md5"), format!("{digest}\n"))
            .map_err(|e| format!("写 md5: {e}"))?;
        // chown 回发起用户(root 写入, 用户可读写)
        chown_user(&backup_path, p.uid);
        chown_user(&backup_path.with_extension("bin.md5"), p.uid);
    }

    // ── 2. 卸载卷(避免写入时系统占用) ──
    let _ = std::process::Command::new("diskutil")
        .args(["unmountDisk", "force", &format!("disk{}", p.disk)]).output();

    // ── 3. 写入: LBA0 最后(改 MBR 触发重扫锁盘, 放最后无后续写受波及) ──
    let mut order: Vec<u64> = lbas.clone();
    order.sort();
    order.retain(|&l| l != 0);
    if p.sectors.contains_key("0") { order.push(0); }
    let unhex = |s: &str| -> Vec<u8> {
        (0..s.len() / 2).map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap()).collect()
    };
    let mut written = Vec::new();
    {
        let mut f = rdisk(p.disk, true).map_err(|e| format!("打开盘(写): {e}"))?;
        for &lba in &order {
            let data = unhex(&p.sectors[&lba.to_string()]);
            f.seek(SeekFrom::Start(lba * 512)).map_err(|e| format!("seek LBA{lba}: {e}"))?;
            f.write_all(&data).map_err(|e| format!("写 LBA{lba}: {e}"))?;
            written.push(lba);
        }
        f.sync_all().map_err(|e| format!("sync: {e}"))?;
    }

    // ── 4. 回读校验 ──
    let mut verified = Vec::new();
    {
        let mut f = rdisk(p.disk, false).map_err(|e| format!("打开盘(校验): {e}"))?;
        let mut one = [0u8; 512];
        for &lba in &order {
            let expect = unhex(&p.sectors[&lba.to_string()]);
            f.seek(SeekFrom::Start(lba * 512)).map_err(|e| format!("seek: {e}"))?;
            f.read_exact(&mut one).map_err(|e| format!("回读 LBA{lba}: {e}"))?;
            if one[..] != expect[..] {
                return Err(format!("LBA{lba} 回读不一致(盘缓存?)"));
            }
            verified.push(lba);
        }
    }
    let _ = fs::remove_file(payload_path);   // 清理 payload
    Ok(WriteResult { ok: true, backup_path: Some(backup_path.to_string_lossy().into_owned()),
        written, verified, error: None })
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
