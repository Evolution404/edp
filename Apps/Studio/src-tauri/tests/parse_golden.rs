//! parse_golden.rs — Rust 解析 vs Python 金标准(parse_golden.json)
//! 覆盖: LBA4 三件套 / LBA6 标签字段+CRC / LBA8 ELABEL / LBA7·12 EDPF entries。

use edpopen_lib::{crypto, parser};

mod support;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap()).collect()
}

#[test]
fn parse_matches_python_golden() {
    let Some(vec) = support::load_json("vectors.json") else { return; };
    let Some(gold) = support::load_json("parse_golden.json") else { return; };
    let disks = gold["disks"].as_array().unwrap();
    let vdisks = vec["disks"].as_array().unwrap();
    assert_eq!(disks.len(), vdisks.len(), "两文件应同盘数同序");

    for (g, v) in disks.iter().zip(vdisks) {
        let name = g["name"].as_str().unwrap();
        assert_eq!(name, v["name"].as_str().unwrap());
        let device_id = v["device_id"].as_str().unwrap();
        let crc = crypto::crc32_bare(device_id.as_bytes());
        let k0 = ((crc & 0xFFFF) ^ ((crc >> 16) & 0xFFFF)) as u16;
        let crc_key = crc.to_le_bytes();
        let raw = |lba: &str| unhex(v["sectors"][lba]["raw_hex"].as_str().unwrap());

        // ── LBA4 ──
        let dec4 = crypto::lba4_decode(&raw("4")).unwrap().0;
        let i4 = parser::parse_lba4_info(&dec4).unwrap();
        let g4 = &g["lba4"];
        assert_eq!(i4.serial, g4["serial"].as_u64().unwrap(), "{name} LBA4 serial");
        assert_eq!(i4.xor8, g4["xor8"].as_str().unwrap(), "{name} xor8");
        assert_eq!(i4.second, g4["second"].as_str().unwrap(), "{name} second");
        assert_eq!(i4.llgb, g4["llgb"].as_bool().unwrap(), "{name} llgb");

        // ── LBA6 ──
        let dec6 = crypto::lba6_decode(&raw("6"));
        let i6 = parser::parse_lba6_info(&dec6, crc);
        let g6 = &g["lba6"];
        assert_eq!(i6.label, g6["label"].as_str().unwrap(), "{name} 标签名");
        assert_eq!(i6.user, g6["user"].as_str().unwrap(), "{name} 用户");
        assert_eq!(i6.serial_ascii, g6["serial_ascii"].as_str().unwrap(), "{name} 序列号");
        assert_eq!(i6.crc_ok, g6["crc_ok"].as_bool().unwrap(), "{name} CRC32");
        assert_eq!(i6.crc_l1_ok, g6["crc_l1_ok"].as_bool().unwrap(), "{name} CRC<<1");
        assert_eq!(i6.safe6, g6["safe6"].as_bool().unwrap(), "{name} SAFE6");
        assert_eq!(i6.glab, g6["glab"].as_str().unwrap(), "{name} GLAB");
        assert_eq!(i6.flag_1f0, g6["flag_1f0"].as_u64().unwrap() as u8, "{name} 注册标志");
        assert_eq!(i6.reg_1ca, g6["reg_1ca"].as_u64().unwrap() as u16, "{name} 0x1CA");

        // ── LBA8 ELABEL ──
        let r8 = raw("8");
        let mut dec8 = crypto::a6b0_full(&r8[..0x170], &crc_key, 0);
        dec8.extend_from_slice(&[0u8; 144]);
        let tags = parser::parse_elabel(&dec8);
        let gt = g["lba8_elabel"].as_array().unwrap();
        assert_eq!(tags.len(), gt.len(), "{name} ELABEL tag 数");
        for (t, ge) in tags.iter().zip(gt) {
            assert_eq!(t.tag, ge["tag"].as_str().unwrap(), "{name} ELABEL tag");
            let gkvs: Vec<&str> = ge["kvs"].as_array().unwrap().iter().map(|x| x.as_str().unwrap()).collect();
            assert_eq!(t.kvs, gkvs, "{name} ELABEL <{}> kvs", t.tag);
        }

        // ── LBA7 / LBA12 EDPF ──
        for (lba, stride, gkey) in [("7", 0x40usize, "lba7_entries"), ("12", 0x60, "lba12_entries")] {
            let r = raw(lba);
            let dec = if lba == "7" {
                crypto::xor_rolling(&r, k0)
            } else {
                let mut d = crypto::a6b0_full(&r[..0x170], &crc_key, 0);
                d.extend_from_slice(&r[0x170..]);
                d
            };
            let entries = parser::parse_edpf(&dec, stride);
            let ge = g[gkey].as_array().unwrap();
            assert_eq!(entries.len(), ge.len(), "{name} LBA{lba} entry 数");
            for (e, x) in entries.iter().zip(ge) {
                assert_eq!(e.ptype, x["type"].as_u64().unwrap() as u32, "{name} LBA{lba} type");
                assert_eq!(e.active, x["active"].as_u64().unwrap() as u32);
                assert_eq!(e.enc_enable, x["enc"].as_u64().unwrap() as u32);
                assert_eq!(e.start, x["start"].as_u64().unwrap());
                assert_eq!(e.size, x["size"].as_u64().unwrap());
                assert_eq!(format!("{:08X}", e.pwd_crc), x["pwd_crc"].as_str().unwrap());
            }
        }
    }
}
