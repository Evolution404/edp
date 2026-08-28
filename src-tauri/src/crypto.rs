//! crypto.rs — 加密原语, 从 Python 版 nopwd.py 逐函数移植。
//!
//! 覆盖: CRC32(bare) / AES-128 变体(A6B0 解密·a7f0 加密, counter XOR 进全部
//! 44 轮密钥字) / 16 位字滚动 XOR(步进 k0 - i(i+1)/2) / LBA6 校验和。
//! 行为与 Python 版逐字节一致, 测试向量见 tests/vectors.json。

pub const KEY_TABLE: &[u8; 16] = b"EDPSECDISK200709";

pub const SBOX: [u8; 256] = [
    99,124,119,123,242,107,111,197,48,1,103,43,254,215,171,118,
    202,130,201,125,250,89,71,240,173,212,162,175,156,164,114,192,
    183,253,147,38,54,63,247,204,52,165,229,241,113,216,49,21,
    4,199,35,195,24,150,5,154,7,18,128,226,235,39,178,117,
    9,131,44,26,27,110,90,160,82,59,214,179,41,227,47,132,
    83,209,0,237,32,252,177,91,106,203,190,57,74,76,88,207,
    208,239,170,251,67,77,51,133,69,249,2,127,80,60,159,168,
    81,163,64,143,146,157,56,245,188,182,218,33,16,255,243,210,
    205,12,19,236,95,151,68,23,196,167,126,61,100,93,25,115,
    96,129,79,220,34,42,144,136,70,238,184,20,222,94,11,219,
    224,50,58,10,73,6,36,92,194,211,172,98,145,149,228,121,
    231,200,55,109,141,213,78,169,108,86,244,234,101,122,174,8,
    186,120,37,46,28,166,180,198,232,221,116,31,75,189,139,138,
    112,62,181,102,72,3,246,14,97,53,87,185,134,193,29,158,
    225,248,152,17,105,217,142,148,155,30,135,233,206,85,40,223,
    140,161,137,13,191,230,66,104,65,153,45,15,176,84,187,22,
];

pub const SBOX2: [u8; 256] = [
    82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,
    124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,
    84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,
    8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37,
    114,248,246,100,134,104,152,22,212,164,92,204,93,101,182,146,
    108,112,72,80,253,237,185,218,94,21,70,87,167,141,157,132,
    144,216,171,0,140,188,211,10,247,228,88,5,184,179,69,6,
    208,44,30,143,202,63,15,2,193,175,189,3,1,19,138,107,
    58,145,17,65,79,103,220,234,151,242,207,206,240,180,230,115,
    150,172,116,34,231,173,53,133,226,249,55,232,28,117,223,110,
    71,241,26,113,29,41,197,137,111,183,98,14,170,24,190,27,
    252,86,62,75,198,210,121,32,154,219,192,254,120,205,90,244,
    31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,
    96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,
    160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,
    23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125,
];

pub const RCON: [u8; 11] = [0, 1, 2, 4, 8, 16, 32, 64, 128, 27, 54];

// ── CRC32 (bare: init=0, poly 0xEDB88320 反射, 无 final-xor) ──────────────
const CRC_TABLE: [u32; 256] = build_crc_table();

const fn build_crc_table() -> [u32; 256] {
    let mut t = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut b = 0;
        while b < 8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xEDB88320 } else { c >> 1 };
            b += 1;
        }
        t[i] = c;
        i += 1;
    }
    t
}

pub fn crc32_bare(data: &[u8]) -> u32 {
    let mut c: u32 = 0;
    for &b in data {
        c = CRC_TABLE[((c ^ b as u32) & 0xFF) as usize] ^ (c >> 8);
    }
    c
}

// ── AES-128 变体 (A6B0 解密 / a7f0 加密) ─────────────────────────────────
// key16 = key_raw 循环填 16B ^ KEY_TABLE; counter 8B(<I counter>+4零)
// XOR 进全部 44 轮密钥字; counter 每块 +16。

fn aes_expand(key16: &[u8; 16]) -> Vec<[u8; 4]> {
    let mut w: Vec<[u8; 4]> = (0..4).map(|i| {
        let i = i * 4;
        [key16[i], key16[i + 1], key16[i + 2], key16[i + 3]]
    }).collect();
    for i in 4..44 {
        let mut t = w[i - 1];
        if i % 4 == 0 {
            t = [t[1], t[2], t[3], t[0]];
            for x in t.iter_mut() { *x = SBOX[*x as usize]; }
            t[0] ^= RCON[i / 4];
        }
        let prev = w[i - 4];
        w.push([t[0] ^ prev[0], t[1] ^ prev[1], t[2] ^ prev[2], t[3] ^ prev[3]]);
    }
    w
}

fn shift_rows(s: &[u8; 16]) -> [u8; 16] {
    [s[0],s[5],s[10],s[15],s[4],s[9],s[14],s[3],s[8],s[13],s[2],s[7],s[12],s[1],s[6],s[11]]
}
fn inv_shift(s: &[u8; 16]) -> [u8; 16] {
    [s[0],s[13],s[10],s[7],s[4],s[1],s[14],s[11],s[8],s[5],s[2],s[15],s[12],s[9],s[6],s[3]]
}

fn gf_mul(mut a: u8, mut b: u8) -> u8 {
    let mut p: u8 = 0;
    for _ in 0..8 {
        if b & 1 != 0 { p ^= a; }
        let h = a & 0x80;
        a = (a << 1) & 0xFF;
        if h != 0 { a ^= 0x1B; }
        b >>= 1;
    }
    p
}

fn mix_column(c: &[u8; 4]) -> [u8; 4] {
    let (a, b, cc, d) = (c[0], c[1], c[2], c[3]);
    [
        gf_mul(a,2) ^ gf_mul(b,3) ^ cc ^ d,
        a ^ gf_mul(b,2) ^ gf_mul(cc,3) ^ d,
        a ^ b ^ gf_mul(cc,2) ^ gf_mul(d,3),
        gf_mul(a,3) ^ b ^ cc ^ gf_mul(d,2),
    ]
}

fn imix(c: &[u8; 4]) -> [u8; 4] {
    let (a, b, cc, d) = (c[0], c[1], c[2], c[3]);
    [
        gf_mul(a,14) ^ gf_mul(b,11) ^ gf_mul(cc,13) ^ gf_mul(d,9),
        gf_mul(a,9) ^ gf_mul(b,14) ^ gf_mul(cc,11) ^ gf_mul(d,13),
        gf_mul(a,13) ^ gf_mul(b,9) ^ gf_mul(cc,14) ^ gf_mul(d,11),
        gf_mul(a,11) ^ gf_mul(b,13) ^ gf_mul(cc,9) ^ gf_mul(d,14),
    ]
}

/// 构造本块的轮密钥(44 词, counter 字节 XOR 调制)
fn modulated_keys(key_raw: &[u8], counter: u32) -> Vec<[u8; 4]> {
    let mut expanded = [0u8; 16];
    for i in 0..16 {
        expanded[i] = key_raw[i % key_raw.len()] ^ KEY_TABLE[i];
    }
    let rk = aes_expand(&expanded);
    let cb = {
        let mut b = [0u8; 8];
        b[..4].copy_from_slice(&counter.to_le_bytes());
        b
    };
    let mut rk = rk;
    for wi in 0..44 {
        for bi in 0..4 {
            rk[wi][bi] ^= cb[(wi * 4 + bi) % 8];
        }
    }
    rk
}

fn xor16(s: &mut [u8; 16], w: &[[u8; 4]]) {
    for i in 0..16 { s[i] ^= w[i / 4][i % 4]; }
}

pub fn a6b0_decrypt_block(data: &[u8; 16], key_raw: &[u8], counter: u32) -> [u8; 16] {
    let rk = modulated_keys(key_raw, counter);
    let mut s = *data;
    xor16(&mut s, &rk[40..44]);                       // 末轮密钥
    for rnd in (1..=9).rev() {
        s = inv_shift(&s);
        for x in s.iter_mut() { *x = SBOX2[*x as usize]; }
        xor16(&mut s, &rk[rnd * 4..(rnd + 1) * 4]);
        for c in 0..4 {
            let col = [s[c * 4], s[c * 4 + 1], s[c * 4 + 2], s[c * 4 + 3]];
            s[c * 4..c * 4 + 4].copy_from_slice(&imix(&col));
        }
    }
    s = inv_shift(&s);
    for x in s.iter_mut() { *x = SBOX2[*x as usize]; }
    xor16(&mut s, &rk[0..4]);
    s
}

pub fn a7f0_encrypt_block(data: &[u8; 16], key_raw: &[u8], counter: u32) -> [u8; 16] {
    let rk = modulated_keys(key_raw, counter);
    let mut s = *data;
    xor16(&mut s, &rk[0..4]);
    for rnd in 1..=9 {
        for x in s.iter_mut() { *x = SBOX[*x as usize]; }
        s = shift_rows(&s);
        for c in 0..4 {
            let col = [s[c * 4], s[c * 4 + 1], s[c * 4 + 2], s[c * 4 + 3]];
            s[c * 4..c * 4 + 4].copy_from_slice(&mix_column(&col));
        }
        xor16(&mut s, &rk[rnd * 4..(rnd + 1) * 4]);
    }
    for x in s.iter_mut() { *x = SBOX[*x as usize]; }
    s = shift_rows(&s);
    xor16(&mut s, &rk[40..44]);
    s
}

/// 逐 16B 块, counter=初始值, 每块 +16
pub fn a6b0_full(data: &[u8], key_raw: &[u8], initial_counter: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut ctr = initial_counter;
    for chunk in data.chunks_exact(16) {
        let mut b = [0u8; 16];
        b.copy_from_slice(chunk);
        out.extend_from_slice(&a6b0_decrypt_block(&b, key_raw, ctr));
        ctr += 16;
    }
    out
}

pub fn a7f0_full(data: &[u8], key_raw: &[u8], initial_counter: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut ctr = initial_counter;
    for chunk in data.chunks_exact(16) {
        let mut b = [0u8; 16];
        b.copy_from_slice(chunk);
        out.extend_from_slice(&a7f0_encrypt_block(&b, key_raw, ctr));
        ctr += 16;
    }
    out
}

// ── 滚动 XOR (16 位小端字, 第 i 字 key = k0 - i(i+1)/2) ──────────────────
pub fn xor_rolling(data: &[u8], k0: u16) -> Vec<u8> {
    let mut r = data.to_vec();
    let mut key = k0;
    for i in 0..(r.len() / 2) {
        let off = i * 2;
        let w = u16::from_le_bytes([r[off], r[off + 1]]) ^ key;
        r[off..off + 2].copy_from_slice(&w.to_le_bytes());
        // Python: key = (key + 0x100 - i - 1) & 0xFFFF  ⇔  key - (i + i(i+1)/2)? 逐字累计:
        // 第 i 字后 key 递减 (i+1): k_i = k0 - i(i+1)/2 ✓
        key = key.wrapping_add(0x100).wrapping_sub((i as u16) + 1);
    }
    r
}

// ── LBA6 (SAFE6) ─────────────────────────────────────────────────────────
pub const LBA6_K0: u16 = 0x4DAA;

/// 对密文前 508B: CRC32(bare) 后 10 轮 ((v>>15)+(v<<1)) 变换
pub fn lba6_checksum(cipher_508: &[u8]) -> u32 {
    let mut c = crc32_bare(cipher_508);
    for _ in 0..10 {
        c = ((c >> 15).wrapping_add(c << 1)) & 0xFFFF_FFFF;
    }
    c
}

/// 前 508B 滚动 XOR 解密, 后 4B 校验和原样
pub fn lba6_decode(raw: &[u8]) -> Vec<u8> {
    let mut out = xor_rolling(&raw[..0x1FC], LBA6_K0);
    out.extend_from_slice(&raw[0x1FC..0x200]);
    out
}

// ── LBA4 标签索引 (ReadTageIndexInfo) ────────────────────────────────────
// 头部 "$$$<labelOnlyId 十进制>$$$" → K0 = low16 ^ high16 (与 LBA7 同款派生)
// → 0x18 起滚动 XOR 解 0x1E8B; 原始 0 字节为未加密零填充, 保持 0。

pub fn lba4_parse_serial(raw: &[u8]) -> Option<u64> {
    let head = &raw[..raw.len().min(64)];
    let mut i = 0;
    while i + 3 <= head.len() {
        if &head[i..i + 3] == b"$$$" {
            let mut j = i + 3;
            while j + 3 <= head.len() {
                if &head[j..j + 3] == b"$$$" {
                    let digits = &head[i + 3..j];
                    if !digits.is_empty() && digits.iter().all(|b| b.is_ascii_digit()) {
                        return std::str::from_utf8(digits).ok()?.parse().ok();
                    }
                    break;
                }
                j += 1;
            }
        }
        i += 1;
    }
    None
}

pub fn lba4_k0_from_serial(serial: u64) -> u16 {
    ((serial & 0xFFFF) ^ ((serial >> 16) & 0xFFFF)) as u16
}

/// 返回 (512B 解密结果, serial)。前 0x18B 明文头原样。
pub fn lba4_decode(raw: &[u8]) -> Option<(Vec<u8>, u64)> {
    let serial = lba4_parse_serial(raw)?;
    let k0 = lba4_k0_from_serial(serial);
    let region = &raw[0x18..0x18 + 0x1E8];
    let mut dec = xor_rolling(region, k0);
    for i in 0..region.len() {
        if region[i] == 0 { dec[i] = 0; }          // 未加密零填充保持 0
    }
    let mut out = raw[..0x18].to_vec();
    out.extend_from_slice(&dec);
    Some((out, serial))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2).map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap()).collect()
    }

    #[test]
    fn crc32_known() {
        // 已知盘值(来自 nopwd.py 实测): lexar=0x6BBAEEFB, aigo长版=0x2EEB4CE1
        assert_eq!(crc32_bare(b"disk&ven_lexar&prod_usb_flash_drive"), 0x6BBAEEFB);
        assert_eq!(crc32_bare(b"disk&ven_aigo&prod_u335&rev_pmap"), 0x2EEB4CE1);
    }

    #[test]
    fn aes_roundtrip() {
        let key: &[u8] = &[0xFB, 0xEE, 0xBA, 0x6B];
        let data: Vec<u8> = (0u32..32).map(|i| (i * 7 + 3) as u8).collect();
        let enc = a7f0_full(&data, key, 0);
        let dec = a6b0_full(&enc, key, 0);
        assert_eq!(dec, data, "a7f0→a6b0 往返应恒等");
    }

    #[test]
    fn xor_rolling_self_inverse() {
        let data: Vec<u8> = (0u32..512).map(|i| (i * 13 + 1) as u8).collect();
        let once = xor_rolling(&data, 0x8541);
        let twice = xor_rolling(&once, 0x8541);
        assert_eq!(twice, data);
    }
}
