//! 裸 CRC32：init=0、poly 0xEDB88320（反射）、无 final XOR。
//! 对照参考实现 `analyze/scripts/read_metadata.py::crc32_bare`。

fn make_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
            k += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
}

static TABLE: std::sync::OnceLock<[u32; 256]> = std::sync::OnceLock::new();

fn table() -> &'static [u32; 256] {
    TABLE.get_or_init(make_table)
}

/// 裸 CRC32（init=0，无 final XOR）。
pub fn crc32_bare(data: &[u8]) -> u32 {
    let t = table();
    let mut c: u32 = 0;
    for &b in data {
        c = t[((c ^ b as u32) & 0xFF) as usize] ^ (c >> 8);
    }
    c
}

/// device_id → 4 字节小端 CRC 密钥（LBA12 A6B0 的 key_raw）。
pub fn crc_key(device_id: &str) -> [u8; 4] {
    crc32_bare(device_id.as_bytes()).to_le_bytes()
}

/// CRC → LBA7 滚动 XOR 初值：low16 ^ high16。
pub fn k0_from_crc(crc: u32) -> u16 {
    ((crc & 0xFFFF) ^ (crc >> 16)) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 黄金值来自 Python 参考实现（fixtures/golden 生成期核对）。
    /// crc32_bare("disk&ven_lexar&prod_usb_flash_drive") = 0x6BBAEEFB（EDPF.md §6）
    #[test]
    fn known_lexar_crc() {
        assert_eq!(
            crc32_bare(b"disk&ven_lexar&prod_usb_flash_drive"),
            0x6BBAEEFB
        );
    }

    /// 默认密码 0000aaaa 的 CRC（三盘实测 +0x30 字段）= 0x0429735D。
    #[test]
    fn known_default_password_crc() {
        assert_eq!(crc32_bare(b"0000aaaa"), 0x0429735D);
    }

    /// 非默认密码（sudo 密码误输场景）必须不匹配。
    #[test]
    fn wrong_password_crc_differs() {
        assert_ne!(crc32_bare(b"631770"), 0x0429735D);
    }

    /// k0 派生：Lexar CRC 0x6BBAEEFB → 0x8541（EDPF.md §6 实测）。
    #[test]
    fn k0_derivation() {
        assert_eq!(k0_from_crc(0x6BBAEEFB), 0x8541);
    }
}
