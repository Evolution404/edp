//! convert_golden.rs — Rust 免密改造 5 扇 vs nopwd.py 产物逐字节对拍。

use edpopen_lib::convert;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap()).collect()
}

#[test]
fn convert_matches_nopwd_py() {
    let vec: serde_json::Value = serde_json::from_str(include_str!("vectors.json")).unwrap();
    let gold: serde_json::Value = serde_json::from_str(include_str!("convert_golden.json")).unwrap();
    let disks = gold["disks"].as_array().unwrap();
    assert!(!disks.is_empty());

    for g in disks {
        let name = g["name"].as_str().unwrap();
        let v = vec["disks"].as_array().unwrap().iter()
            .find(|v| v["name"].as_str().unwrap() == name).expect("向量与 golden 应同名对齐");
        let raw = |lba: &str| unhex(v["sectors"][lba]["raw_hex"].as_str().unwrap());
        let crc = u32::from_str_radix(g["crc32"].as_str().unwrap(), 16).unwrap();
        let k0 = u16::from_str_radix(g["k0"].as_str().unwrap(), 16).unwrap();
        let raw0 = unhex(g["raw0"].as_str().unwrap());

        let plan = convert::convert(&raw0, &raw("6"), &raw("7"), &raw("9"), &raw("12"), crc, k0, None)
            .unwrap_or_else(|e| panic!("{name}: {e}"));

        assert_eq!(plan.share, g["share"].as_u64().unwrap(), "{name} share");
        assert_eq!(plan.enc_start, g["enc_start"].as_u64().unwrap());
        assert_eq!(plan.enc_size, g["enc_size"].as_u64().unwrap());
        for key in ["lba0", "lba6", "lba7", "lba12"] {
            assert_eq!(hexs(&plan_field(&plan, key)), g[key].as_str().unwrap(),
                "{name} {key} 与 nopwd.py 产物不一致");
        }
        match g["lba9"].as_str() {
            Some(h) => assert_eq!(hexs(plan.lba9.as_ref().unwrap()), h, "{name} lba9"),
            None => assert!(plan.lba9.is_none(), "{name} lba9 应不写"),
        }
    }
}

fn plan_field<'a>(p: &'a convert::ConvertPlan, key: &str) -> &'a [u8] {
    match key {
        "lba0" => &p.lba0, "lba6" => &p.lba6, "lba7" => &p.lba7, _ => &p.lba12,
    }
}

fn hexs(b: &[u8]) -> String { b.iter().map(|x| format!("{x:02x}")).collect() }
