//! 开发验证工具：从黄金数据 + 明文数据区构造合成 EDP 盘。
//! 用法：make-synthetic <golden_dir> <plain.bin> <out.img> [partition_type]

use edp_core::synthetic::{build, SyntheticSpec};

fn unhex(s: &str) -> Vec<u8> {
    hex::decode(s).unwrap()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (golden, plain_path, out_path, ptype) = match args.as_slice() {
        [_, g, p, o] => (g, p, o, 4u32),
        [_, g, p, o, t] => (g, p, o, t.parse().unwrap()),
        _ => {
            eprintln!("用法: make-synthetic <golden_dir> <plain.bin> <out.img> [partition_type]");
            std::process::exit(2);
        }
    };
    let disks: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(format!("{golden}/disks.json")).unwrap())
            .unwrap();
    let d = disks["disks"].as_array().unwrap()[0].clone(); // disk4 真实 Lexar
    let mut plain = std::fs::read(plain_path).unwrap();
    if plain.len() % 16 != 0 {
        plain.resize(plain.len().div_ceil(16) * 16, 0);
    }
    let img = build(&SyntheticSpec {
        lba7_cipher: &unhex(d["lba7"]["cipher_hex"].as_str().unwrap()),
        lba11_cipher: &unhex(d["lba11"]["cipher_hex"].as_str().unwrap()),
        lba12_cipher: &unhex(d["lba12"]["cipher_hex"].as_str().unwrap()),
        device_id: d["device_id"].as_str().unwrap(),
        password: d["password"].as_str().unwrap(),
        partition_type: ptype,
        plaintext: &plain,
    })
    .unwrap();
    std::fs::write(out_path, &img).unwrap();
    println!(
        "OK: {} 字节（数据区 {} 字节，type={ptype}）-> {out_path}",
        img.len(),
        plain.len()
    );
}
