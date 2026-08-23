//! EDP 加密 U 盘客户端 GUI 后端。
//!
//! - 常驻状态栏（tray，无 Dock 图标；`activationPolicy: accessory`）
//! - 经 UDS JSON-RPC 调用 daemon（复用 edp-proto）
//! - 订阅 daemon 事件（mounted/unmounted/…）→ 系统通知 + 托盘菜单动态重建
//! - macFUSE 检测 / daemon 安装（osascript 提权）

use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_notification::NotificationExt;

/// daemon socket 路径（客户端侧；测试可用 EDP_USB_SOCKET 覆盖）。
#[derive(Default)]
pub struct Rpc {
    socket: String,
}

impl Rpc {
    fn socket_path() -> String {
        std::env::var_os("EDP_USB_SOCKET")
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "/var/run/edp-usbcore.sock".to_string())
    }

    fn new() -> Self {
        Rpc {
            socket: Self::socket_path(),
        }
    }

    /// 一次 RPC 调用（每次新建连接：daemon 可随时重启）。
    pub fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let mut c = edp_proto::Client::connect(&self.socket)
            .map_err(|e| format!("无法连接 daemon（{}）：{e}", self.socket))?;
        c.call(method, params).map_err(|e| e.to_string())
    }
}

/// 托盘句柄（事件后动态重建菜单）。
pub struct TrayState(Mutex<Option<TrayIcon>>);

const EVENT_NAME: &str = "edp://event";

// ---------- 命令 ----------

/// daemon 状态；离线时返回 Err（前端据此显示引导）。
#[tauri::command]
fn daemon_status(rpc: State<Rpc>) -> Result<Value, String> {
    rpc.call(edp_proto::method::STATUS, json!({}))
}

/// 通用 RPC 转发（方法白名单由 daemon 决定）。
#[tauri::command]
fn rpc(rpc: State<Rpc>, method: String, params: Value) -> Result<Value, String> {
    rpc.call(&method, params)
}

/// macFUSE 检测。
#[tauri::command]
fn macfuse_status() -> Value {
    let installed = Path::new("/Library/Filesystems/macfuse.fs").exists();
    let version = edp_macos::macfuse_version();
    json!({ "installed": installed, "version": version })
}

/// 提权安装 daemon（osascript）。
#[tauri::command]
fn install_daemon() -> Result<Value, String> {
    let bin = find_usbcore()?;
    run_admin(&format!("{} daemon install", shell_quote(&bin)))?;
    Ok(json!({ "ok": true, "bin": bin }))
}

/// 提权卸载 daemon。
#[tauri::command]
fn uninstall_daemon() -> Result<Value, String> {
    let bin = find_usbcore()?;
    run_admin(&format!("{} daemon uninstall", shell_quote(&bin)))?;
    Ok(json!({ "ok": true }))
}

/// Finder 打开挂载点。
#[tauri::command]
fn open_in_finder(path: String) -> Result<(), String> {
    std::process::Command::new("open")
        .arg(&path)
        .output()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// 显示主窗口。
#[tauri::command]
fn show_main(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

// ---------- 托盘 ----------

fn build_tray_menu(app: &AppHandle) -> Result<Menu<tauri::Wry>, tauri::Error> {
    let rpc = Rpc::new();
    let menu = Menu::new(app)?;

    // 挂载中的会话
    let sessions_arr = rpc
        .call(edp_proto::method::SESSIONS, json!({}))
        .ok()
        .and_then(|v| v["sessions"].as_array().cloned())
        .unwrap_or_default();
    if sessions_arr.is_empty() {
        let online = rpc.call(edp_proto::method::STATUS, json!({})).is_ok();
        let label = if online { "（无挂载中的卷）" } else { "daemon 离线" };
        menu.append(&MenuItem::with_id(app, "none", label, false, None::<&str>)?)?;
    } else {
        for s in sessions_arr {
            let sid = s["session_id"].as_str().unwrap_or("?").to_string();
            let mp = s["mountpoint"].as_str().unwrap_or("?").to_string();
            let item = MenuItem::with_id(
                app,
                format!("sess-{sid}"),
                format!("🔒 {mp}"),
                true,
                None::<&str>,
            )?;
            menu.append(&item)?;
        }
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;

    // 打开主窗口
    menu.append(&MenuItem::with_id(
        app,
        "open",
        "打开 EDP USB Client",
        true,
        None::<&str>,
    )?)?;

    // 自动挂载开关
    let auto = rpc
        .call(edp_proto::method::CONFIG_GET, json!({}))
        .ok()
        .and_then(|v| v["auto_mount_enabled"].as_bool())
        .unwrap_or(false);
    menu.append(&CheckMenuItem::with_id(
        app,
        "toggle_auto",
        "自动挂载",
        auto,
        true,
        None::<&str>,
    )?)?;

    // macFUSE 状态
    let macfuse = Path::new("/Library/Filesystems/macfuse.fs").exists();
    let label = if macfuse {
        format!("macFUSE {}", edp_macos::macfuse_version().unwrap_or_default())
    } else {
        "macFUSE 未安装 → 打开设置".to_string()
    };
    menu.append(&MenuItem::with_id(
        app, "macfuse", label, true, None::<&str>,
    )?)?;

    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?)?;
    Ok(menu)
}

fn setup_tray(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_tray_menu(app)?;
    let tray = TrayIconBuilder::new()
        .icon(app.default_window_icon().cloned().unwrap())
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app.clone()),
            "quit" => app.exit(0),
            "toggle_auto" => {
                // 翻转当前状态（事件不直接携带勾选值）
                let rpc = Rpc::new();
                let cur = rpc
                    .call(edp_proto::method::CONFIG_GET, json!({}))
                    .ok()
                    .and_then(|v| v["auto_mount_enabled"].as_bool())
                    .unwrap_or(false);
                let _ = rpc.call(
                    edp_proto::method::CONFIG_SET,
                    json!({ "auto_mount_enabled": !cur }),
                );
                let _ = rebuild_tray(app);
            }
            id if id.starts_with("sess-") => {
                let sid = id.trim_start_matches("sess-");
                let rpc = Rpc::new();
                if let Ok(v) = rpc.call(edp_proto::method::SESSIONS, json!({})) {
                    if let Some(mp) = v["sessions"]
                        .as_array()
                        .and_then(|a| a.iter().find(|s| s["session_id"] == sid))
                        .and_then(|s| s["mountpoint"].as_str())
                    {
                        let _ = std::process::Command::new("open").arg(mp).spawn();
                    }
                }
            }
            "macfuse" => {
                show_main(app.clone());
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.eval("location.hash='#/settings'");
                }
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main(tray.app_handle().clone());
            }
        })
        .build(app)?;
    *app.state::<TrayState>().0.lock().unwrap() = Some(tray);
    Ok(())
}

fn rebuild_tray(app: &AppHandle) -> tauri::Result<()> {
    if let Some(tray) = app.state::<TrayState>().0.lock().unwrap().as_ref() {
        tray.set_menu(Some(build_tray_menu(app)?))?;
    }
    Ok(())
}

// ---------- 事件订阅 ----------

fn spawn_subscriber(app: AppHandle) {
    std::thread::spawn(move || {
        let socket = Rpc::socket_path();
        loop {
            let mut c = match edp_proto::Client::connect(&socket) {
                Ok(c) => c,
                Err(_) => {
                    std::thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };
            let app2 = app.clone();
            let _ = c.subscribe(move |ev| {
                let _ = app2.emit(EVENT_NAME, ev.clone());
                let _ = rebuild_tray(&app2);
                let title = match ev.event.as_str() {
                    edp_proto::event::MOUNTED => "EDP 卷已挂载",
                    edp_proto::event::UNMOUNTED => "EDP 卷已卸载",
                    edp_proto::event::PASSWORD_NEEDED => "需要密码",
                    _ => "EDP 事件",
                };
                let body = ev
                    .data
                    .get("mountpoint")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&ev.event)
                    .to_string();
                let _ = app2.notification().builder().title(title).body(body).show();
            });
            std::thread::sleep(Duration::from_secs(2));
        }
    });
}

// ---------- daemon 安装辅助 ----------

fn find_usbcore() -> Result<String, String> {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let sibling = dir.join("usbcore");
            if sibling.exists() {
                return Ok(sibling.to_string_lossy().into_owned());
            }
        }
    }
    for p in ["/usr/local/bin/usbcore", "/usr/local/libexec/usbcore"] {
        if Path::new(p).exists() {
            return Ok(p.to_string());
        }
    }
    Err("未找到 usbcore 二进制（请先构建或 `make install`）".into())
}

fn shell_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn run_admin(script: &str) -> Result<(), String> {
    let full = format!(
        "do shell script {} with administrator privileges",
        shell_quote(script)
    );
    let out = std::process::Command::new("osascript")
        .arg("-e")
        .arg(&full)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

// ---------- 入口 ----------

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .invoke_handler(tauri::generate_handler![
            daemon_status,
            rpc,
            macfuse_status,
            install_daemon,
            uninstall_daemon,
            open_in_finder,
            show_main,
        ])
        .manage(Rpc::new())
        .setup(|app| {
            // 常驻状态栏、无 Dock 图标
            let _ = app.handle().set_activation_policy(tauri::ActivationPolicy::Accessory);
            app.manage(TrayState(Mutex::new(None)));
            setup_tray(app.handle())?;
            spawn_subscriber(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
