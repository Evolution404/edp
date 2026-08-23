//! LBA7 滚动 16 位 XOR 编解码（自对称）。
//! 对照参考实现 `read_metadata.py::xor_decode`：每 16 位字 XOR 当前 key，
//! 第 i 个字处理后 `key = (key + 0x100 - i - 1) & 0xFFFF`。

/// 原地滚动 XOR：同一调用即加密即解密。
pub fn xor_decode(data: &mut [u8], k0: u16) {
    let mut key = k0 as u32;
    for i in 0..data.len() / 2 {
        let w = u16::from_le_bytes([data[i * 2], data[i * 2 + 1]]) ^ (key as u16);
        data[i * 2..i * 2 + 2].copy_from_slice(&w.to_le_bytes());
        key = (key + 0x100 - i as u32 - 1) & 0xFFFF;
    }
}

/// 便捷版：返回新缓冲。
pub fn xor_decode_copy(data: &[u8], k0: u16) -> Vec<u8> {
    let mut buf = data.to_vec();
    xor_decode(&mut buf, k0);
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 自对称：连续两次调用还原。
    #[test]
    fn self_inverse() {
        let data: Vec<u8> = (0..96u8).cycle().take(96).collect();
        let once = xor_decode_copy(&data, 0x8541);
        let twice = xor_decode_copy(&once, 0x8541);
        assert_eq!(twice, data);
    }

    /// 首字 XOR 行为：第 0 字只 XOR k0，key 递减从第 1 字生效。
    #[test]
    fn first_word_only_xors_k0() {
        let mut data = [0x12u8, 0x34, 0x00, 0x00];
        let plain_first = u16::from_le_bytes([0x12, 0x34]) ^ 0x8541u16;
        xor_decode(&mut data, 0x8541);
        assert_eq!(u16::from_le_bytes([data[0], data[1]]), plain_first);
    }
}
