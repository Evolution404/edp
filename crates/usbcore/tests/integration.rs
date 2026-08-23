//! 集成测试：合成盘全链路（需 macOS + macFUSE；`make test-integration`）。
//!
//! 流程照搬 Python 版 test_native_exfat_mount.py 思路：
//! hdiutil 造 exFAT 镜像 → edp-core 合成加密盘 → usbcore probe/mount →
//! 写文件 → unmount → 重挂验证持久化 → readonly 拒写 → 错误密码。

use std::path::PathBuf;
use std::process::Command;

fn exe() -> PathBuf {
    // 集成测试二进制位于 target/debug/deps/，主二进制在 target/debug/usbcore
    let cur = std::env::current_exe().unwrap();
    let dir = cur.parent().unwrap(); // deps/ 或 debug/
    if dir.file_name().and_then(|n| n.to_str()) == Some("deps") {
        dir.parent().unwrap().join("usbcore")
    } else {
        dir.join("usbcore")
    }
}

fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/golden")
}

/// hdiutil 造 exFAT 并提取分区明文。
fn make_plain_exfat(td: &std::path::Path) -> Vec<u8> {
    let dmg = td.join("source.dmg");
    assert!(Command::new("hdiutil")
        .args(["create", "-size", "32m", "-fs", "ExFAT", "-volname", "EDPTEST", "-type", "UDIF"])
        .arg(&dmg)
        .output()
        .unwrap()
        .status
        .success());
    let out = Command::new("hdiutil")
        .args(["attach", "-plist", "-nomount"])
        .arg(&dmg)
        .output()
        .unwrap();
    let v: plist::Value = plist::from_bytes(&out.stdout).unwrap();
    let mut partition = String::new();
    let mut whole = String::new();
    for e in v.as_dictionary().unwrap()["system-entities"]
        .as_array()
        .unwrap()
    {
        let d = e.as_dictionary().unwrap();
        if let Some(dev) = d.get("dev-entry").and_then(plist::Value::as_string) {
            if d.get("potentially-mountable")
                .and_then(plist::Value::as_boolean)
                .unwrap_or(false)
            {
                partition = dev.to_string();
            }
            whole = dev.split('s').next().unwrap_or(dev).to_string();
        }
    }
    let info = Command::new("diskutil")
        .args(["info", "-plist"])
        .arg(&partition)
        .output()
        .unwrap();
    let iv: plist::Value = plist::from_bytes(&info.stdout).unwrap();
    let size = iv.as_dictionary().unwrap()["TotalSize"]
        .as_unsigned_integer()
        .unwrap();
    let raw = partition.replace("/dev/disk", "/dev/rdisk");
    use std::os::unix::fs::FileExt;
    let f = std::fs::File::open(&raw).unwrap();
    let mut data = vec![0u8; size as usize];
    // 分区设备整读：分段 read_exact_at（rdiskN 一次性整读会 EINVAL）
    let chunk = 1 << 20;
    let mut off = 0u64;
    while off < size {
        let n = ((size - off) as usize).min(chunk);
        f.read_exact_at(&mut data[off as usize..off as usize + n], off)
            .unwrap();
        off += n as u64;
    }
    drop(f);
    let _ = Command::new("hdiutil").args(["detach", &whole]).output();
    assert_eq!(data.len() as u64, size);
    assert_eq!(&data[3..11], b"EXFAT   ", "exFAT 签名缺失");
    data
}

fn make_synthetic(td: &std::path::Path, plain: &[u8]) -> PathBuf {
    let img = td.join("edp.img");
    let disks: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(golden_dir().join("disks.json")).unwrap())
            .unwrap();
    let d = &disks["disks"].as_array().unwrap()[0];
    let unhex = |s: &str| hex::decode(s).unwrap();
    let mut plain = plain.to_vec();
    if plain.len() % 16 != 0 {
        plain.resize(plain.len().div_ceil(16) * 16, 0);
    }
    let img_data = edp_core::synthetic::build(&edp_core::synthetic::SyntheticSpec {
        lba7_cipher: &unhex(d["lba7"]["cipher_hex"].as_str().unwrap()),
        lba11_cipher: &unhex(d["lba11"]["cipher_hex"].as_str().unwrap()),
        lba12_cipher: &unhex(d["lba12"]["cipher_hex"].as_str().unwrap()),
        device_id: d["device_id"].as_str().unwrap(),
        password: d["password"].as_str().unwrap(),
        partition_type: 4,
        plaintext: &plain,
    })
    .unwrap();
    std::fs::write(&img, img_data).unwrap();
    img
}

/// 全链路：probe → mount → 写 → unmount → 重挂 → 持久化 → readonly → 错误密码。
#[test]
#[ignore = "需要 macOS + macFUSE；sudo cargo test -- --ignored"]
fn synthetic_full_pipeline() {
    let td = tempfile_dir();
    let session_root = td.join("sessions");
    let plain = make_plain_exfat(&td);
    let img = make_synthetic(&td, &plain);

    // 强制离线模式：CLI mount 在线优先，但测试用 --device-id/--session-id
    // 等仅离线支持参数，必须绕过已运行的 daemon
    let offline_sock = td.join("no-daemon.sock");
    let env_vars = [
        ("EDP_USB_SESSION_ROOT", session_root.to_str().unwrap()),
        ("EDP_USB_SOCKET", offline_sock.to_str().unwrap()),
    ];
    let run_env = |args: &[&str]| {
        let mut cmd = Command::new(exe());
        cmd.args(args);
        for (k, v) in env_vars {
            cmd.env(k, v);
        }
        let out = cmd.output().unwrap();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).to_string(),
            String::from_utf8_lossy(&out.stderr).to_string(),
        )
    };

    let dev_id = "disk&ven_lexar&prod_usb_flash_drive";

    // probe 闭环
    let (ok, out, _) = run_env(&[
        "probe",
        img.to_str().unwrap(),
        "--device-id",
        dev_id,
        "--password",
        "0000aaaa",
    ]);
    assert!(ok, "probe 失败");
    assert!(out.contains("\"ok\": true"));
    assert!(out.contains("EXFAT"));

    // 错误密码拒绝
    let (ok, _, err) = run_env(&[
        "probe",
        img.to_str().unwrap(),
        "--device-id",
        dev_id,
        "--password",
        "wrongpwd",
    ]);
    assert!(!ok, "错误密码应失败");
    assert!(err.contains("密码错误"), "错误密码信息不符: {err}");

    // mount（镜像文件无需 sudo）
    let (ok, out, err) = run_env(&[
        "mount",
        img.to_str().unwrap(),
        "--device-id",
        dev_id,
        "--password",
        "0000aaaa",
        "--session-id",
        "it-main",
    ]);
    if !ok {
        panic!("mount 失败: stderr={err} stdout={out}");
    }
    let state: serde_json::Value = serde_json::from_str(&out)
        .or_else(|_| {
            // tracing 日志可能混入 stdout 前缀行：取第一个 '{' 之后的 JSON
            let json_part = &out[out.find('{').unwrap_or(0)..];
            serde_json::from_str(json_part)
        })
        .unwrap_or_else(|e| panic!("解析 mount 输出失败: {e} stdout={out}"));
    let mp = state["mountpoints"][0].as_str().unwrap().to_string();
    assert!(mp.starts_with("/Volumes/"), "挂载点异常: {mp}");

    // 写入
    let proof = format!("integration-{}", std::process::id());
    std::fs::write(format!("{mp}/proof.txt"), &proof).unwrap();

    // 卸载 → 重挂 → 持久化
    let (ok, _, err) = run_env(&["unmount", "it-main"]);
    assert!(ok, "unmount 失败: {err}");
    let (ok, out, err) = run_env(&[
        "mount",
        img.to_str().unwrap(),
        "--device-id",
        dev_id,
        "--password",
        "0000aaaa",
        "--session-id",
        "it-main2",
    ]);
    assert!(ok, "重挂失败: {err}");
    let state: serde_json::Value = serde_json::from_str(&out).unwrap();
    let mp2 = state["mountpoints"][0].as_str().unwrap().to_string();
    assert_eq!(
        std::fs::read_to_string(format!("{mp2}/proof.txt")).unwrap(),
        proof,
        "写入未持久化"
    );
    let (ok, _, _) = run_env(&["unmount", "it-main2"]);
    assert!(ok);

    // readonly 挂载拒写
    let (ok, out, err) = run_env(&[
        "mount",
        img.to_str().unwrap(),
        "--device-id",
        dev_id,
        "--password",
        "0000aaaa",
        "--readonly",
        "--session-id",
        "it-ro",
    ]);
    assert!(ok, "readonly mount 失败: {err}");
    let state: serde_json::Value = serde_json::from_str(&out).unwrap();
    let mpro = state["mountpoints"][0].as_str().unwrap().to_string();
    assert!(
        std::fs::write(format!("{mpro}/ro.txt"), "x").is_err(),
        "readonly 应拒写"
    );
    let (ok, _, _) = run_env(&["unmount", "it-ro"]);
    assert!(ok);
}

fn tempfile_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "edp-it-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4().simple()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
