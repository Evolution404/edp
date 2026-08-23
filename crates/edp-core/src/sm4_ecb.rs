//! SM4 分组密码（GB/T 32907-2016）+ ECB 模式。
//! RustCrypto 的 `sm4 0.0.1` 依赖已从 crates.io 移除的 `block-cipher-trait 0.6`，
//! 故按标准手写；正确性由黄金向量（含真实盘 file_key 解包）单测保证。

use crate::CoreError;

/// SM4 S 盒。
const SBOX: [u8; 256] = [
    0xd6, 0x90, 0xe9, 0xfe, 0xcc, 0xe1, 0x3d, 0xb7, 0x16, 0xb6, 0x14, 0xc2, 0x28, 0xfb, 0x2c, 0x05,
    0x2b, 0x67, 0x9a, 0x76, 0x2a, 0xbe, 0x04, 0xc3, 0xaa, 0x44, 0x13, 0x26, 0x49, 0x86, 0x06, 0x99,
    0x9c, 0x42, 0x50, 0xf4, 0x91, 0xef, 0x98, 0x7a, 0x33, 0x54, 0x0b, 0x43, 0xed, 0xcf, 0xac, 0x62,
    0xe4, 0xb3, 0x1c, 0xa9, 0xc9, 0x08, 0xe8, 0x95, 0x80, 0xdf, 0x94, 0xfa, 0x75, 0x8f, 0x3f, 0xa6,
    0x47, 0x07, 0xa7, 0xfc, 0xf3, 0x73, 0x17, 0xba, 0x83, 0x59, 0x3c, 0x19, 0xe6, 0x85, 0x4f, 0xa8,
    0x68, 0x6b, 0x81, 0xb2, 0x71, 0x64, 0xda, 0x8b, 0xf8, 0xeb, 0x0f, 0x4b, 0x70, 0x56, 0x9d, 0x35,
    0x1e, 0x24, 0x0e, 0x5e, 0x63, 0x58, 0xd1, 0xa2, 0x25, 0x22, 0x7c, 0x3b, 0x01, 0x21, 0x78, 0x87,
    0xd4, 0x00, 0x46, 0x57, 0x9f, 0xd3, 0x27, 0x52, 0x4c, 0x36, 0x02, 0xe7, 0xa0, 0xc4, 0xc8, 0x9e,
    0xea, 0xbf, 0x8a, 0xd2, 0x40, 0xc7, 0x38, 0xb5, 0xa3, 0xf7, 0xf2, 0xce, 0xf9, 0x61, 0x15, 0xa1,
    0xe0, 0xae, 0x5d, 0xa4, 0x9b, 0x34, 0x1a, 0x55, 0xad, 0x93, 0x32, 0x30, 0xf5, 0x8c, 0xb1, 0xe3,
    0x1d, 0xf6, 0xe2, 0x2e, 0x82, 0x66, 0xca, 0x60, 0xc0, 0x29, 0x23, 0xab, 0x0d, 0x53, 0x4e, 0x6f,
    0xd5, 0xdb, 0x37, 0x45, 0xde, 0xfd, 0x8e, 0x2f, 0x03, 0xff, 0x6a, 0x72, 0x6d, 0x6c, 0x5b, 0x51,
    0x8d, 0x1b, 0xaf, 0x92, 0xbb, 0xdd, 0xbc, 0x7f, 0x11, 0xd9, 0x5c, 0x41, 0x1f, 0x10, 0x5a, 0xd8,
    0x0a, 0xc1, 0x31, 0x88, 0xa5, 0xcd, 0x7b, 0xbd, 0x2d, 0x74, 0xd0, 0x12, 0xb8, 0xe5, 0xb4, 0xb0,
    0x89, 0x69, 0x97, 0x4a, 0x0c, 0x96, 0x77, 0x7e, 0x65, 0xb9, 0xf1, 0x09, 0xc5, 0x6e, 0xc6, 0x84,
    0x18, 0xf0, 0x7d, 0xec, 0x3a, 0xdc, 0x4d, 0x20, 0x79, 0xee, 0x5f, 0x3e, 0xd7, 0xcb, 0x39, 0x48,
];

/// 系统参数 FK。
const FK: [u32; 4] = [0xA3B1_BAC6, 0x56AA_3350, 0x677D_9197, 0xB270_22DC];

/// 常量参数 CK（标准定义：CK_{i,j} = (4i+j)·7 mod 256）。
const fn make_ck() -> [u32; 32] {
    let mut ck = [0u32; 32];
    let mut i = 0;
    while i < 32 {
        let mut j = 0;
        let mut v = 0u32;
        while j < 4 {
            let b = (((4 * i + j) as u32) * 7 % 256) as u8;
            v = (v << 8) | b as u32;
            j += 1;
        }
        ck[i] = v;
        i += 1;
    }
    ck
}

const CK: [u32; 32] = make_ck();

#[inline]
fn rotl(x: u32, n: u32) -> u32 {
    x.rotate_left(n)
}

/// τ 变换（S 盒逐字节替换）。
fn tau(a: u32) -> u32 {
    (SBOX[((a >> 24) & 0xFF) as usize] as u32) << 24
        | (SBOX[((a >> 16) & 0xFF) as usize] as u32) << 16
        | (SBOX[((a >> 8) & 0xFF) as usize] as u32) << 8
        | (SBOX[(a & 0xFF) as usize] as u32)
}

/// L 变换（加密轮函数用）。
fn l(b: u32) -> u32 {
    b ^ rotl(b, 2) ^ rotl(b, 10) ^ rotl(b, 18) ^ rotl(b, 24)
}

/// L' 变换（密钥扩展用）。
fn l_key(b: u32) -> u32 {
    b ^ rotl(b, 13) ^ rotl(b, 23)
}

fn t_enc(a: u32) -> u32 {
    l(tau(a))
}

fn t_key(a: u32) -> u32 {
    l_key(tau(a))
}

/// 单块 SM4 加/解密（解密用逆序轮密钥）。
fn crypt_block(block: &[u8; 16], round_keys: &[u32; 32]) -> [u8; 16] {
    let mut x = [
        u32::from_be_bytes(block[0..4].try_into().unwrap()),
        u32::from_be_bytes(block[4..8].try_into().unwrap()),
        u32::from_be_bytes(block[8..12].try_into().unwrap()),
        u32::from_be_bytes(block[12..16].try_into().unwrap()),
    ];
    for rk in round_keys {
        let n = x[1] ^ x[2] ^ x[3] ^ rk;
        x = [x[1], x[2], x[3], x[0] ^ t_enc(n)];
    }
    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&x[3].to_be_bytes());
    out[4..8].copy_from_slice(&x[2].to_be_bytes());
    out[8..12].copy_from_slice(&x[1].to_be_bytes());
    out[12..16].copy_from_slice(&x[0].to_be_bytes());
    out
}

fn expand_key(key: &[u8; 16]) -> [u32; 32] {
    let mut mk = [
        FK[0] ^ u32::from_be_bytes(key[0..4].try_into().unwrap()),
        FK[1] ^ u32::from_be_bytes(key[4..8].try_into().unwrap()),
        FK[2] ^ u32::from_be_bytes(key[8..12].try_into().unwrap()),
        FK[3] ^ u32::from_be_bytes(key[12..16].try_into().unwrap()),
    ];
    let mut rk = [0u32; 32];
    for i in 0..32 {
        let n = mk[1] ^ mk[2] ^ mk[3] ^ CK[i];
        rk[i] = mk[0] ^ t_key(n);
        mk = [mk[1], mk[2], mk[3], rk[i]];
    }
    rk
}

/// SM4-ECB：持密钥的加解密器（输入必须 16 字节对齐）。
pub struct Sm4Ecb {
    enc_keys: [u32; 32],
    /// 解密轮密钥 = 加密轮密钥逆序。
    dec_keys: [u32; 32],
}

impl Sm4Ecb {
    /// 以 16 字节密钥构造。
    pub fn new(key: &[u8; 16]) -> Self {
        let enc_keys = expand_key(key);
        let mut dec_keys = enc_keys;
        dec_keys.reverse();
        Sm4Ecb { enc_keys, dec_keys }
    }

    fn run(&self, data: &[u8], keys: &[u32; 32]) -> Result<Vec<u8>, CoreError> {
        if data.len() % 16 != 0 {
            return Err(CoreError::InvalidInput(format!(
                "SM4-ECB 输入必须 16 字节对齐，实际 {}",
                data.len()
            )));
        }
        Ok(data
            .chunks_exact(16)
            .flat_map(|c| crypt_block(c.try_into().unwrap(), keys))
            .collect())
    }

    /// ECB 加密（对齐输入）。
    pub fn encrypt_aligned(&self, data: &[u8]) -> Result<Vec<u8>, CoreError> {
        self.run(data, &self.enc_keys)
    }

    /// ECB 解密（对齐输入）。
    pub fn decrypt_aligned(&self, data: &[u8]) -> Result<Vec<u8>, CoreError> {
        self.run(data, &self.dec_keys)
    }
}

/// file_key 解包的固定 wrapping key：MD5(b"LtSWi[2f)j")。
pub fn wrapping_key() -> [u8; 16] {
    use md5::Digest;
    let mut h = md5::Md5::new();
    h.update(b"LtSWi[2f)j");
    h.finalize().into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    /// GB/T 32907-2016 标准向量：
    /// 明文 0123456789abcdeffedcba9876543210
    /// 密钥 0123456789abcdeffedcba9876543210
    /// 密文 681edf34d206965e86b3e94f536e4246
    #[test]
    fn standard_vector() {
        let key: [u8; 16] = hex!("0123456789abcdeffedcba9876543210");
        let pt: [u8; 16] = hex!("0123456789abcdeffedcba9876543210");
        let expect: [u8; 16] = hex!("681edf34d206965e86b3e94f536e4246");
        let sm4 = Sm4Ecb::new(&key);
        assert_eq!(sm4.encrypt_aligned(&pt).unwrap(), expect);
        assert_eq!(sm4.decrypt_aligned(&expect).unwrap(), pt);
    }

    /// 真实 Lexar 盘 file_key 解包闭环（EDPF.md §4 实测）：
    /// SM4_Decrypt(56fd7c10288df7fd8752dc94bb2d5eee, MD5("LtSWi[2f)j"))
    /// = 1a28e58ce2c0e3eb16877ad38586f2e2
    #[test]
    fn lexar_file_key_unwrap() {
        let salt: [u8; 16] = hex!("56fd7c10288df7fd8752dc94bb2d5eee");
        let expect: [u8; 16] = hex!("1a28e58ce2c0e3eb16877ad38586f2e2");
        let sm4 = Sm4Ecb::new(&wrapping_key());
        assert_eq!(sm4.decrypt_aligned(&salt).unwrap(), expect);
    }

    /// 非对齐输入必须报错。
    #[test]
    fn misaligned_rejected() {
        let sm4 = Sm4Ecb::new(&[0u8; 16]);
        assert!(sm4.encrypt_aligned(&[0u8; 15]).is_err());
    }
}
