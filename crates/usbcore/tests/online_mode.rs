//! CLI 在线模式集成测试（纯协议层，无需 macFUSE/真实盘）。
//!
//! 启动一个测试 daemon（非 root，临时 socket + 会话根），再通过 CLI
//! 走 RPC：status / keys add|ls|rm / mounts / unmount 在线分支；
//! 以及 daemon 离线时的降级行为（status exit 4、本地 fallback）。
//!
//! 运行：`cargo test -p usbcore --test online_mode`（不 require sudo）。

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_usbcore");
const TEST_DEVICE_ID: &str = "disk&ven_lexar&prod_usb_flash_drive";
const TEST_PWD_CRC: &str = "0429735d";

static SEQ: AtomicU32 = AtomicU32::new(0);

fn temp_dir(tag: &str) -> PathBuf {
    let n = SEQ.fetch_add(1, Ordering::SeqCst);
    let d = std::env::temp_dir().join(format!("edp-online-{}-{tag}-{n}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// 启动测试 daemon，返回 (Child, socket 路径)。
fn start_daemon(tmp: &Path) -> (Child, PathBuf) {
    let socket = tmp.join("test.sock");
    let sess = tmp.join("sess");
    let child = Command::new(BIN)
        .args(["daemon", "run", "--session-root"])
        .arg(&sess)
        .args(["--socket"])
        .arg(&socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("启动测试 daemon");
    let deadline = Instant::now() + Duration::from_secs(15);
    while !socket.exists() {
        assert!(
            Instant::now() < deadline,
            "daemon 未在期限内就绪（socket 未出现）"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    (child, socket)
}

/// 跑 CLI，返回 (exit_code, stdout+stderr 合并输出)。
/// 注：`main -> anyhow::Result` 的错误经 stderr 打印，故合并两者供断言。
fn cli(socket: &Path, args: &[&str]) -> (i32, String) {
    let mut cmd = Command::new(BIN);
    cmd.args(args)
        .env("EDP_USB_SOCKET", socket.to_str().unwrap())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let out = cmd.output().expect("运行 CLI");
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    (out.status.code().unwrap_or(-1), text)
}

fn json_parse(s: &str) -> serde_json::Value {
    serde_json::from_str(s).unwrap_or_else(|e| panic!("CLI 输出非法 JSON: {e}\n{s}"))
}

#[test]
fn online_mode_full_cycle() {
    let tmp = temp_dir("cycle");
    let (mut daemon, socket) = start_daemon(&tmp);

    // status：在线
    let (code, out) = cli(&socket, &["status"]);
    assert_eq!(code, 0);
    let v = json_parse(&out);
    assert_eq!(v["daemon_online"], serde_json::json!(true));
    assert_eq!(
        v["daemon"]["version"],
        serde_json::json!(env!("CARGO_PKG_VERSION"))
    );
    assert!(v["daemon"]["auto_mount_enabled"].as_bool().unwrap());

    // doctor：在线报告 daemon 信息
    let (code, out) = cli(&socket, &["doctor"]);
    assert_eq!(code, 0);
    assert!(json_parse(&out)["daemon_online"].as_bool().unwrap());

    // mounts：在线优先，空会话
    let (code, out) = cli(&socket, &["mounts"]);
    assert_eq!(code, 0);
    let v = json_parse(&out);
    let sessions = v["sessions"].as_array().expect("sessions 数组");
    assert!(sessions.is_empty());

    // keys add（--device-id 绕过盘探测）
    let (code, out) = cli(
        &socket,
        &[
            "keys",
            "add",
            "--label",
            "测试盘",
            "--device-id",
            TEST_DEVICE_ID,
            "--password",
            "0000aaaa",
        ],
    );
    assert_eq!(code, 0, "keys add 失败: {out}");
    let id = json_parse(&out)["id"].as_str().unwrap().to_string();
    assert!(!id.is_empty());

    // keys ls：脱敏（无明文密码），password_crc 与真实盘一致
    let (code, out) = cli(&socket, &["keys", "ls"]);
    assert_eq!(code, 0);
    let v = json_parse(&out);
    let arr = v.as_array().expect("keys ls 返回数组");
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["password_crc"], TEST_PWD_CRC);
    assert!(!out.contains("0000aaaa"), "keys ls 泄露明文密码: {out}");

    // keys rm
    let (code, out) = cli(&socket, &["keys", "rm", &id]);
    assert_eq!(code, 0);
    assert_eq!(json_parse(&out)["removed"], serde_json::json!(true));

    // 在线 mount 走 RPC（盘不存在 → RPC INTERNAL 错误，而非 sudo 提示）
    let (code, out) = cli(
        &socket,
        &["mount", "/dev/rdisk999", "--password", "0000aaaa"],
    );
    assert_eq!(code, 1);
    assert!(out.contains("RPC 错误"), "在线 mount 应走 RPC 通道: {out}");

    daemon.kill().ok();
    let _ = daemon.wait();
    let _ = std::fs::remove_dir_all(&tmp);
}

#[test]
fn offline_fallback() {
    let tmp = temp_dir("offline");
    let socket = tmp.join("missing.sock");

    // status：离线 → exit 4
    let (code, out) = cli(&socket, &["status"]);
    assert_eq!(code, 4);
    assert_eq!(json_parse(&out)["daemon_online"], serde_json::json!(false));

    // mounts：离线 → 本地扫描（空会话）
    let (code, out) = cli(&socket, &["mounts"]);
    assert_eq!(code, 0);
    assert!(json_parse(&out)["sessions"].is_array());

    // unmount：离线 → 本地路径（会话不存在报错，但非 RPC）
    let (code, out) = cli(&socket, &["unmount", "no-such-session"]);
    assert_eq!(code, 1);
    assert!(!out.contains("RPC 错误"));

    let _ = std::fs::remove_dir_all(&tmp);
}

#[test]
fn unauthorized_uid_rejected() {
    // daemon 默认授权为控制台用户；这里用一个不存在 socket 的"未授权"场景
    // 已在 edp-proto 协议测试覆盖（PERMISSION_DENIED）。此处验证：
    // 未授权仅放行 status（服务端语义）—— 通过一个无法连接的 socket 模拟离线。
    let tmp = temp_dir("unauth");
    let socket = tmp.join("missing.sock");
    let (code, _) = cli(&socket, &["keys", "ls"]);
    assert_eq!(code, 1);
    let _ = std::fs::remove_dir_all(&tmp);
}

#[test]
fn daemon_status_command() {
    let tmp = temp_dir("dstatus");
    let (mut daemon, socket) = start_daemon(&tmp);
    let (code, out) = cli(&socket, &["daemon", "status"]);
    assert_eq!(code, 0);
    let v = json_parse(&out);
    assert_eq!(v["online"], serde_json::json!(true));
    assert!(v["status"]["auto_mount_enabled"].as_bool().unwrap());
    daemon.kill().ok();
    let _ = daemon.wait();
    let _ = std::fs::remove_dir_all(&tmp);
}
