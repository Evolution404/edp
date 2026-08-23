//! EDP 魔改 AES：A6B0（解密方向）与 A7F0（加密方向）。
//!
//! 与标准 AES-128 的差异（对照 `read_metadata.py::a6b0_decrypt/a7f0_encrypt`）：
//! 1. **密钥白化**：`expanded = key_raw 循环填充 16B ^ b"EDPSECDISK200709"`
//! 2. **counter 掩码**：`cb = LE32(counter) || 00 00 00 00`（8B），全部 44 个轮密钥字
//!    的第 `bi` 字节 XOR `cb[(wi*4+bi) % 8]`
//! 3. **counter 步进**：每处理一个 16B 块，counter += 16
//!
//! counter=0 时 cb 全零、轮密钥退化为标准 AES-128 轮密钥，A6B0/A7F0 分别等价于
//! 标准 AES-128 的解密/加密——单测用 RustCrypto `aes` 交叉验证这一特例。

/// 密钥白化常量表。
pub const KEY_TABLE: &[u8; 16] = b"EDPSECDISK200709";

/// AES S 盒。
pub const SBOX: [u8; 256] = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

/// AES 逆 S 盒。
const INV_SBOX: [u8; 256] = {
    let mut inv = [0u8; 256];
    let mut i = 0;
    while i < 256 {
        inv[SBOX[i] as usize] = i as u8;
        i += 1;
    }
    inv
};

const RCON: [u8; 11] = [
    0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
];

/// GF(2^8) 乘法（模多项式 x^8+x^4+x^3+x+1）。
fn gf_mul(mut a: u8, mut b: u8) -> u8 {
    let mut p = 0u8;
    for _ in 0..8 {
        if b & 1 != 0 {
            p ^= a;
        }
        let high = a & 0x80;
        a = a.wrapping_shl(1);
        if high != 0 {
            a ^= 0x1b;
        }
        b >>= 1;
    }
    p
}

type Words = [[u8; 4]; 44];

/// 标准 AES-128 密钥扩展（word-wise，与参考实现 `aes_expand` 一致）。
pub fn aes_expand(key: &[u8; 16]) -> Words {
    let mut w: Words = [[0; 4]; 44];
    for i in 0..4 {
        w[i].copy_from_slice(&key[i * 4..i * 4 + 4]);
    }
    for i in 4..44 {
        let mut t = w[i - 1];
        if i % 4 == 0 {
            t.rotate_left(1); // RotWord
            for b in t.iter_mut() {
                *b = SBOX[*b as usize];
            }
            t[0] ^= RCON[i / 4];
        }
        for j in 0..4 {
            w[i][j] = w[i - 4][j] ^ t[j];
        }
    }
    w
}

/// 密钥白化 + 扩展 + counter 掩码，产出展平的 11 个轮密钥（flat[r] 为第 r 轮）。
pub fn derive_round_keys(key_raw: &[u8], counter: u32) -> [[u8; 16]; 11] {
    let mut expanded = [0u8; 16];
    for (i, b) in expanded.iter_mut().enumerate() {
        *b = key_raw[i % key_raw.len()] ^ KEY_TABLE[i];
    }
    let mut rk = aes_expand(&expanded);
    if counter != 0 {
        let cb = [counter.to_le_bytes(), [0u8; 4]].concat();
        for wi in 0..44 {
            for bi in 0..4 {
                rk[wi][bi] ^= cb[(wi * 4 + bi) % 8];
            }
        }
    }
    let mut flat = [[0u8; 16]; 11];
    for r in 0..11 {
        for wi in 0..4 {
            flat[r][wi * 4..wi * 4 + 4].copy_from_slice(&rk[r * 4 + wi]);
        }
    }
    flat
}

/// 行移位（作用于 16B 状态的置换，标准 AES ShiftRows）。
pub fn shift_rows(s: &mut [u8; 16]) {
    let o = *s;
    for (i, &v) in [
        o[0], o[5], o[10], o[15], o[4], o[9], o[14], o[3], o[8], o[13], o[2], o[7], o[12], o[1],
        o[6], o[11],
    ]
    .iter()
    .enumerate()
    {
        s[i] = v;
    }
}

/// 逆行移位。
fn inv_shift_rows(s: &mut [u8; 16]) {
    let o = *s;
    for (i, &v) in [
        o[0], o[13], o[10], o[7], o[4], o[1], o[14], o[11], o[8], o[5], o[2], o[15], o[12], o[9],
        o[6], o[3],
    ]
    .iter()
    .enumerate()
    {
        s[i] = v;
    }
}

pub fn mix_column(col: &mut [u8; 4]) {
    let a = *col;
    col[0] = gf_mul(a[0], 2) ^ gf_mul(a[1], 3) ^ a[2] ^ a[3];
    col[1] = a[0] ^ gf_mul(a[1], 2) ^ gf_mul(a[2], 3) ^ a[3];
    col[2] = a[0] ^ a[1] ^ gf_mul(a[2], 2) ^ gf_mul(a[3], 3);
    col[3] = gf_mul(a[0], 3) ^ a[1] ^ a[2] ^ gf_mul(a[3], 2);
}

fn inv_mix_column(col: &mut [u8; 4]) {
    let a = *col;
    col[0] = gf_mul(a[0], 14) ^ gf_mul(a[1], 11) ^ gf_mul(a[2], 13) ^ gf_mul(a[3], 9);
    col[1] = gf_mul(a[0], 9) ^ gf_mul(a[1], 14) ^ gf_mul(a[2], 11) ^ gf_mul(a[3], 13);
    col[2] = gf_mul(a[0], 13) ^ gf_mul(a[1], 9) ^ gf_mul(a[2], 14) ^ gf_mul(a[3], 11);
    col[3] = gf_mul(a[0], 11) ^ gf_mul(a[1], 13) ^ gf_mul(a[2], 9) ^ gf_mul(a[3], 14);
}

fn xor16(s: &mut [u8; 16], k: &[u8; 16]) {
    for i in 0..16 {
        s[i] ^= k[i];
    }
}

/// A6B0 单块解密（魔改 AES-128 解密轮序 + counter 掩码轮密钥）。
pub fn a6b0_block(block: &[u8; 16], key_raw: &[u8], counter: u32) -> [u8; 16] {
    let flat = derive_round_keys(key_raw, counter);
    let mut s = *block;
    xor16(&mut s, &flat[10]);
    for rnd in (1..=9).rev() {
        inv_shift_rows(&mut s);
        for b in s.iter_mut() {
            *b = INV_SBOX[*b as usize];
        }
        xor16(&mut s, &flat[rnd]);
        for c in 0..4 {
            let col = &mut s[c * 4..c * 4 + 4];
            inv_mix_column(col.try_into().unwrap());
        }
    }
    inv_shift_rows(&mut s);
    for b in s.iter_mut() {
        *b = INV_SBOX[*b as usize];
    }
    xor16(&mut s, &flat[0]);
    s
}

/// A7F0 单块加密。
pub fn a7f0_block(block: &[u8; 16], key_raw: &[u8], counter: u32) -> [u8; 16] {
    let flat = derive_round_keys(key_raw, counter);
    let mut s = *block;
    xor16(&mut s, &flat[0]);
    for rk in flat.iter().skip(1).take(9) {
        for b in s.iter_mut() {
            *b = SBOX[*b as usize];
        }
        shift_rows(&mut s);
        for c in 0..4 {
            let col = &mut s[c * 4..c * 4 + 4];
            mix_column(col.try_into().unwrap());
        }
        xor16(&mut s, rk);
    }
    for b in s.iter_mut() {
        *b = SBOX[*b as usize];
    }
    shift_rows(&mut s);
    xor16(&mut s, &flat[10]);
    s
}

/// A6B0 多块解密：每块 counter += 16。
pub fn a6b0_full(data: &[u8], key_raw: &[u8], initial_counter: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut ctr = initial_counter;
    for chunk in data.chunks_exact(16) {
        out.extend_from_slice(&a6b0_block(chunk.try_into().unwrap(), key_raw, ctr));
        ctr += 16;
    }
    out
}

/// A7F0 多块加密：每块 counter += 16。
pub fn a7f0_full(data: &[u8], key_raw: &[u8], initial_counter: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut ctr = initial_counter;
    for chunk in data.chunks_exact(16) {
        out.extend_from_slice(&a7f0_block(chunk.try_into().unwrap(), key_raw, ctr));
        ctr += 16;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};

    fn whitened_key(key_raw: &[u8]) -> [u8; 16] {
        let mut expanded = [0u8; 16];
        for (i, b) in expanded.iter_mut().enumerate() {
            *b = key_raw[i % key_raw.len()] ^ KEY_TABLE[i];
        }
        expanded
    }

    /// counter=0 时 A6B0/A7F0 等价于标准 AES-128（用 RustCrypto aes 交叉验证）。
    #[test]
    fn cross_check_counter_zero_vs_standard_aes() {
        use aes::cipher::generic_array::GenericArray;
        let keys: [&[u8]; 3] = [
            &[0x6b, 0xba, 0xee, 0xfb], // lexar CRC key
            b"EDPSECDISK200709",
            &(0..16u8).collect::<Vec<u8>>(),
        ];
        let block: [u8; 16] = core::array::from_fn(|i| (i * 37 + 11) as u8);
        for key_raw in keys {
            let cipher = aes::Aes128::new(&GenericArray::from(whitened_key(key_raw)));
            let mut buf = GenericArray::from(block);
            cipher.encrypt_block(&mut buf);
            let enc: [u8; 16] = buf.into();
            assert_eq!(
                a7f0_block(&block, key_raw, 0),
                enc,
                "a7f0 加密不等价 key={key_raw:?}"
            );
            let mut buf2 = GenericArray::from(block);
            cipher.decrypt_block(&mut buf2);
            let dec: [u8; 16] = buf2.into();
            assert_eq!(
                a6b0_block(&block, key_raw, 0),
                dec,
                "a6b0 解密不等价 key={key_raw:?}"
            );
        }
    }

    /// a7f0(a6b0(x)) == x（同 counter），覆盖 counter != 0 的掩码路径。
    #[test]
    fn roundtrip_with_counter() {
        let data: Vec<u8> = (0..96u8)
            .map(|i| i.wrapping_mul(7).wrapping_add(3))
            .collect();
        let keys: [&[u8]; 2] = [&[0xb8, 0xb2, 0x68, 0x1d], b"0123456789abcdef"];
        for key in keys {
            for ctr in [0u32, 16, 0x1234] {
                let dec = a6b0_full(&data, key, ctr);
                let enc = a7f0_full(&dec, key, ctr);
                assert_eq!(enc, data, "往返失败 key={key:?} ctr={ctr}");
            }
        }
    }

    /// 不同 counter 产生不同密文（掩码确实生效）。
    #[test]
    fn counter_changes_output() {
        let block = [0x42u8; 16];
        let key = b"EDPSECDISK200709";
        assert_ne!(a6b0_block(&block, key, 0), a6b0_block(&block, key, 16));
    }
}
