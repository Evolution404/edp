//! LBA11：PDKB 块解出制盘写入的 device_id。
//!
//! 结构：`raw[..0x100]` 为 rand，`raw[0x100..0x200]` 为密文。
//! key = `LE32(crc32_bare(rand ‖ VID(4B) ‖ PID(4B) ‖ LE64(sz)))`，
//! 对 (真实容量, CHS 向下取整容量) 两个候选尝试，解出 `PDKB` magic 后
//! 取其后 NUL 前的 ASCII 即 device_id。
//! VID/PID/容量由系统层（edp-macos）提供，本模块保持纯函数。

use crate::crc32::crc32_bare;
use crate::edp_aes::a6b0_full;

/// CHS 向下取整容量（heads=255、spt=63、bps=512）。
pub fn chs_capacity(size: u64) -> u64 {
    let cyl_bytes: u64 = 255 * 63 * 512;
    (size / cyl_bytes) * cyl_bytes
}

fn ascii_pad4(s: &str) -> [u8; 4] {
    let mut out = [0u8; 4];
    for (i, b) in s.as_bytes().iter().take(4).enumerate() {
        out[i] = *b;
    }
    out
}

/// 从 LBA11 原始扇区解出 device_id；失败返回 None（提示走 identify 候选兜底）。
pub fn device_id_from_lba11(
    raw: &[u8; 512],
    vid_hex: &str,
    pid_hex: &str,
    size_bytes: u64,
) -> Option<String> {
    let rand = &raw[..0x100];
    let cipher = &raw[0x100..0x200];
    let vid_b = ascii_pad4(vid_hex);
    let pid_b = ascii_pad4(pid_hex);
    for sz in [size_bytes, chs_capacity(size_bytes)] {
        let mut mat = Vec::with_capacity(0x100 + 8 + 8 + 8);
        mat.extend_from_slice(rand);
        mat.extend_from_slice(&vid_b);
        mat.extend_from_slice(&pid_b);
        mat.extend_from_slice(&sz.to_le_bytes());
        let key = crc32_bare(&mat).to_le_bytes();
        let pt = a6b0_full(cipher, &key, 0);
        if pt[..4] == *b"PDKB" {
            let end = pt[4..].iter().position(|&b| b == 0).unwrap_or(pt.len() - 4);
            let dev = String::from_utf8_lossy(&pt[4..4 + end]).to_string();
            if !dev.is_empty() {
                return Some(dev);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chs_capacity_floor() {
        // 124736503808 / (255*63*512) = 15165 余 132608，向下取整
        assert_eq!(chs_capacity(124_736_503_808), 15165 * 255 * 63 * 512);
        // 小于一个柱面 → 0
        assert_eq!(chs_capacity(1024), 0);
    }

    #[test]
    fn pad4_behavior() {
        assert_eq!(ascii_pad4("21c4"), *b"21c4");
        assert_eq!(ascii_pad4("ab"), [b'a', b'b', 0, 0]);
    }
}
