//! EDP USB Client UI v2 Tauri backend.
//!
//! The webview and tray consume one cached snapshot. Daemon events are debounced
//! into snapshot refreshes so the UI never maintains an independent truth.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_notification::NotificationExt;

const SOCKET_PATH: &str = "/var/run/edp-usbcore.sock";
const INSTALLED_USB_CORE: &str = "/usr/local/libexec/usbcore";
const SNAPSHOT_EVENT: &str = "ui://snapshot";
const OPERATION_EVENT: &str = "ui://operation";
const RAW_EVENT: &str = "edp://event";

#[derive(Default)]
pub struct Rpc {
    socket: String,
}

impl Rpc {
    fn socket_path() -> String {
        std::env::var_os("EDP_USB_SOCKET")
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| SOCKET_PATH.to_string())
    }

    fn new() -> Self {
        Self {
            socket: Self::socket_path(),
        }
    }

    fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let mut client = edp_proto::Client::connect(&self.socket)
            .map_err(|error| format!("无法连接 daemon（{}）：{error}", self.socket))?;
        client.call(method, params).map_err(|error| error.to_string())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct AppSnapshot {
    revision: u64,
    generated_at: String,
    service: Value,
    daemon: Option<Value>,
    auto_mount_mode: String,
    devices: Vec<Value>,
    sessions: Vec<Value>,
    credentials: Vec<Value>,
    macfuse: Value,
    last_error: Option<String>,
}

impl Default for AppSnapshot {
    fn default() -> Self {
        Self {
            revision: 0,
            generated_at: now(),
            service: json!({
                "installed": Path::new(INSTALLED_USB_CORE).exists(),
                "running": false,
                "enabled": false,
                "online": false,
            }),
            daemon: None,
            auto_mount_mode: "active".to_string(),
            devices: Vec::new(),
            sessions: Vec::new(),
            credentials: Vec::new(),
            macfuse: macfuse_value(),
            last_error: None,
        }
    }
}

pub struct UiStateCoordinator {
    revision: AtomicU64,
    snapshot: Mutex<AppSnapshot>,
    refresh_lock: Mutex<()>,
    refresh_pending: AtomicBool,
}

impl Default for UiStateCoordinator {
    fn default() -> Self {
        Self {
            revision: AtomicU64::new(0),
            snapshot: Mutex::new(AppSnapshot::default()),
            refresh_lock: Mutex::new(()),
            refresh_pending: AtomicBool::new(false),
        }
    }
}

impl UiStateCoordinator {
    fn current(&self) -> AppSnapshot {
        self.snapshot.lock().unwrap().clone()
    }

    fn refresh(&self) -> AppSnapshot {
        let _refresh = self.refresh_lock.lock().unwrap();
        let previous = self.current();
        let rpc = Rpc::new();
        let service = service_status_impl().unwrap_or_else(|error| {
            json!({
                "installed": Path::new(INSTALLED_USB_CORE).exists(),
                "running": false,
                "enabled": false,
                "online": false,
                "error": error.message,
            })
        });

        let (daemon, auto_mount_mode, devices, sessions, credentials, last_error) =
            match rpc.call(edp_proto::method::STATUS, json!({})) {
                Ok(status) => {
                    let mut error = None;
                    let (devices, mode) = match rpc.call(edp_proto::method::DEVICES_LIST, json!({})) {
                        Ok(value) => (
                            value["devices"].as_array().cloned().unwrap_or_default(),
                            value["auto_mount_mode"]
                                .as_str()
                                .unwrap_or(&previous.auto_mount_mode)
                                .to_string(),
                        ),
                        Err(message) => {
                            error = Some(message);
                            (previous.devices.clone(), previous.auto_mount_mode.clone())
                        }
                    };
                    let sessions = rpc
                        .call(edp_proto::method::SESSIONS, json!({}))
                        .ok()
                        .and_then(|value| value["sessions"].as_array().cloned())
                        .unwrap_or_default();
                    let credentials = rpc
                        .call(edp_proto::method::KEYS_LS, json!({}))
                        .ok()
                        .and_then(|value| value.as_array().cloned())
                        .unwrap_or_else(|| previous.credentials.clone());
                    (Some(status), mode, devices, sessions, credentials, error)
                }
                Err(message) => (
                    None,
                    previous.auto_mount_mode.clone(),
                    previous.devices.clone(),
                    Vec::new(),
                    previous.credentials.clone(),
                    Some(message),
                ),
            };

        let snapshot = AppSnapshot {
            revision: self.revision.fetch_add(1, Ordering::SeqCst) + 1,
            generated_at: now(),
            service,
            daemon,
            auto_mount_mode,
            devices,
            sessions,
            credentials,
            macfuse: macfuse_value(),
            last_error,
        };
        *self.snapshot.lock().unwrap() = snapshot.clone();
        snapshot
    }
}

pub struct TrayState(Mutex<Option<TrayIcon>>);

#[derive(Debug, Clone, Serialize)]
struct UiError {
    code: String,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

impl UiError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
            detail: None,
        }
    }

    fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }
}

#[derive(Debug, Clone, Serialize)]
struct OperationEvent {
    id: String,
    action: String,
    phase: String,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<UiError>,
}

#[derive(Debug, Clone, Serialize)]
struct ServiceActionResult {
    action: String,
    service: Value,
    snapshot: AppSnapshot,
}

#[derive(Debug, Deserialize)]
struct CredentialInput {
    #[serde(default)]
    id: Option<String>,
    label: String,
    device_id: String,
    #[serde(default)]
    disk: Option<String>,
    partition_type: u32,
    password: String,
}

fn now() -> String {
    chrono::Local::now().to_rfc3339()
}

fn operation_id(action: &str) -> String {
    format!("{action}-{}", chrono::Utc::now().timestamp_millis())
}

fn macfuse_value() -> Value {
    json!({
        "installed": Path::new("/Library/Filesystems/macfuse.fs").exists(),
        "version": edp_macos::macfuse_version(),
    })
}

fn first_mountpoint(value: &Value) -> Option<String> {
    value["mountpoints"]
        .as_array()
        .and_then(|items| items.first())
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn partition_label(value: &Value) -> &'static str {
    match value["partition"]["partition_type"].as_u64() {
        Some(2) => "交换区",
        Some(4) => "保密区",
        _ => "EDP 卷",
    }
}

fn publish_snapshot(app: &AppHandle) -> AppSnapshot {
    let snapshot = app.state::<UiStateCoordinator>().refresh();
    let _ = app.emit(SNAPSHOT_EVENT, snapshot.clone());
    let _ = rebuild_tray(app, &snapshot);
    snapshot
}

fn schedule_snapshot_refresh(app: AppHandle) {
    let coordinator = app.state::<UiStateCoordinator>();
    if coordinator.refresh_pending.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        let _ = publish_snapshot(&app);
        app.state::<UiStateCoordinator>()
            .refresh_pending
            .store(false, Ordering::SeqCst);
    });
}

fn emit_operation(
    app: &AppHandle,
    id: &str,
    action: &str,
    phase: &str,
    message: &str,
    error: Option<UiError>,
) {
    let _ = app.emit(
        OPERATION_EVENT,
        OperationEvent {
            id: id.to_string(),
            action: action.to_string(),
            phase: phase.to_string(),
            message: message.to_string(),
            error,
        },
    );
}

// ---------- typed commands ----------

#[tauri::command]
fn get_app_snapshot(coordinator: State<UiStateCoordinator>) -> AppSnapshot {
    if coordinator.current().revision == 0 {
        coordinator.refresh()
    } else {
        coordinator.current()
    }
}

#[tauri::command]
fn refresh_app_snapshot(app: AppHandle) -> AppSnapshot {
    publish_snapshot(&app)
}

#[tauri::command]
fn set_auto_mount_mode(app: AppHandle, mode: String) -> Result<AppSnapshot, UiError> {
    if !matches!(mode.as_str(), "active" | "paused") {
        return Err(UiError::new("BAD_PARAMS", "自动挂载状态无效"));
    }
    Rpc::new()
        .call(
            edp_proto::method::AUTO_MOUNT_SET_MODE,
            json!({ "mode": mode }),
        )
        .map_err(|message| UiError::new("RPC_FAILED", "无法更新自动挂载状态").with_detail(message))?;
    Ok(publish_snapshot(&app))
}

#[tauri::command]
fn set_device_policy(app: AppHandle, policy: Value) -> Result<AppSnapshot, UiError> {
    Rpc::new()
        .call(edp_proto::method::DEVICES_POLICY_SET, policy)
        .map_err(|message| UiError::new("RPC_FAILED", "无法保存设备授权").with_detail(message))?;
    Ok(publish_snapshot(&app))
}

#[tauri::command]
fn mount_partition(
    app: AppHandle,
    disk: String,
    device_id: String,
    partition_type: u32,
) -> Result<AppSnapshot, UiError> {
    Rpc::new()
        .call(
            edp_proto::method::MOUNT,
            json!({ "disk": disk, "device_id": device_id, "partition_type": partition_type }),
        )
        .map_err(|message| UiError::new("MOUNT_FAILED", "挂载失败").with_detail(message))?;
    Ok(publish_snapshot(&app))
}

#[tauri::command]
fn unmount_session(
    app: AppHandle,
    session_id: String,
    force: Option<bool>,
) -> Result<AppSnapshot, UiError> {
    Rpc::new()
        .call(
            edp_proto::method::UNMOUNT,
            json!({ "session_id": session_id, "force": force.unwrap_or(false) }),
        )
        .map_err(|message| UiError::new("UNMOUNT_FAILED", "卸载失败").with_detail(message))?;
    Ok(publish_snapshot(&app))
}

#[tauri::command]
fn save_credential(app: AppHandle, input: CredentialInput) -> Result<AppSnapshot, UiError> {
    if input.password.is_empty() {
        return Err(UiError::new("BAD_PARAMS", "密码不能为空"));
    }
    let disk = input
        .disk
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| UiError::new("DEVICE_OFFLINE", "设备离线，无法验证新密码"))?;
    let rpc = Rpc::new();
    rpc.call(
        edp_proto::method::PROBE,
        json!({
            "disk": disk,
            "password": input.password,
            "partition_type": input.partition_type,
        }),
    )
    .map_err(|message| UiError::new("PASSWORD_INVALID", "密码验证失败").with_detail(message))?;

    if let Some(id) = input.id {
        rpc.call(
            edp_proto::method::KEYS_UPDATE,
            json!({ "id": id, "label": input.label, "password": input.password }),
        )
    } else {
        rpc.call(
            edp_proto::method::KEYS_ADD,
            json!({
                "label": input.label,
                "device_id": input.device_id,
                "partition_type": input.partition_type,
                "password": input.password,
            }),
        )
    }
    .map_err(|message| UiError::new("CREDENTIAL_SAVE_FAILED", "无法保存凭据").with_detail(message))?;
    Ok(publish_snapshot(&app))
}

#[tauri::command]
fn delete_credential(app: AppHandle, id: String) -> Result<AppSnapshot, UiError> {
    Rpc::new()
        .call(edp_proto::method::KEYS_RM, json!({ "id": id }))
        .map_err(|message| UiError::new("CREDENTIAL_DELETE_FAILED", "无法删除凭据").with_detail(message))?;
    Ok(publish_snapshot(&app))
}

#[tauri::command]
fn get_diagnostics(coordinator: State<UiStateCoordinator>) -> Value {
    let logs = Rpc::new()
        .call(edp_proto::method::LOGS_READ, json!({ "lines": 200 }))
        .unwrap_or_else(|error| json!({ "logs": [], "error": error }));
    json!({ "snapshot": coordinator.current(), "logs": logs["logs"] })
}

#[tauri::command]
fn open_in_finder(path: String) -> Result<(), UiError> {
    if path.is_empty() {
        return Err(UiError::new("BAD_PARAMS", "没有可打开的挂载点"));
    }
    std::process::Command::new("open")
        .arg(&path)
        .spawn()
        .map(|_| ())
        .map_err(|error| UiError::new("OPEN_FAILED", "无法在 Finder 中打开").with_detail(error.to_string()))
}

#[tauri::command]
fn show_main(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

// ---------- service lifecycle ----------

fn resolve_service_binary(installed: &Path, debug_candidates: &[PathBuf]) -> Option<PathBuf> {
    if installed.exists() {
        return Some(installed.to_path_buf());
    }
    if cfg!(debug_assertions) {
        return debug_candidates.iter().find(|path| path.exists()).cloned();
    }
    None
}

fn service_binary() -> Result<PathBuf, UiError> {
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target");
    let debug_candidates = [workspace.join("debug/usbcore"), workspace.join("release/usbcore")];
    resolve_service_binary(Path::new(INSTALLED_USB_CORE), &debug_candidates)
        .ok_or_else(|| UiError::new("SERVICE_NOT_INSTALLED", "后台服务尚未安装"))
}

fn install_source(app: &AppHandle) -> Result<PathBuf, UiError> {
    if let Ok(resource_dir) = app.path().resource_dir() {
        let bundled = resource_dir.join("usbcore");
        if bundled.exists() {
            return Ok(bundled);
        }
    }
    if Path::new(INSTALLED_USB_CORE).exists() {
        return Ok(PathBuf::from(INSTALLED_USB_CORE));
    }
    if cfg!(debug_assertions) {
        let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target");
        for candidate in [workspace.join("release/usbcore"), workspace.join("debug/usbcore")] {
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }
    Err(UiError::new(
        "INSTALL_SOURCE_MISSING",
        "应用包中缺少 usbcore 安装组件",
    ))
}

fn service_status_impl() -> Result<Value, UiError> {
    let installed = Path::new(INSTALLED_USB_CORE).exists()
        && Path::new("/Library/LaunchDaemons/com.edp.usbcore.plist").exists();
    let Some(binary) = resolve_service_binary(Path::new(INSTALLED_USB_CORE), &[]) else {
        return Ok(json!({
            "installed": installed,
            "running": Path::new(SOCKET_PATH).exists(),
            "enabled": false,
            "online": Path::new(SOCKET_PATH).exists(),
        }));
    };
    let output = std::process::Command::new(binary)
        .args(["daemon", "status"])
        .output()
        .map_err(|error| UiError::new("STATUS_FAILED", "无法读取服务状态").with_detail(error.to_string()))?;
    if !output.status.success() {
        return Err(UiError::new("STATUS_FAILED", "无法读取服务状态")
            .with_detail(String::from_utf8_lossy(&output.stderr).trim()));
    }
    serde_json::from_slice(&output.stdout).map_err(|error| {
        UiError::new("STATUS_INVALID", "服务返回了无效状态").with_detail(error.to_string())
    })
}

fn shell_quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn run_admin(script: &str) -> Result<(), UiError> {
    let apple_script = format!(
        "do shell script {} with administrator privileges",
        shell_quote(script)
    );
    let output = std::process::Command::new("osascript")
        .arg("-e")
        .arg(apple_script)
        .output()
        .map_err(|error| UiError::new("ADMIN_FAILED", "无法请求管理员授权").with_detail(error.to_string()))?;
    if output.status.success() {
        return Ok(());
    }
    let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if detail.contains("User canceled") || detail.contains("-128") || detail.contains("用户已取消") {
        return Err(UiError::new("ADMIN_CANCELLED", "已取消管理员授权"));
    }
    Err(UiError::new("SERVICE_CONTROL_FAILED", "后台服务操作失败").with_detail(detail))
}

fn service_action_complete(action: &str, status: &Value) -> bool {
    let installed = status["installed"].as_bool().unwrap_or(false);
    let running = status["running"].as_bool().unwrap_or(false);
    let enabled = status["enabled"].as_bool().unwrap_or(false);
    match action {
        "install" | "start" | "restart" => installed && running && enabled,
        "stop" => installed && !running && !enabled,
        "uninstall" => !installed && !running,
        _ => false,
    }
}

fn verify_service_action(action: &str) -> Result<(), UiError> {
    let mut last_status = None;
    for _ in 0..40 {
        if let Ok(status) = service_status_impl() {
            if service_action_complete(action, &status) {
                return Ok(());
            }
            last_status = Some(status);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(UiError::new("VERIFY_TIMEOUT", "后台服务状态验证超时").with_detail(
        last_status
            .map(|status| status.to_string())
            .unwrap_or_else(|| "无法读取服务状态".to_string()),
    ))
}

#[tauri::command]
async fn run_service_action(app: AppHandle, action: String) -> Result<ServiceActionResult, UiError> {
    if !matches!(action.as_str(), "install" | "start" | "stop" | "restart" | "uninstall") {
        return Err(UiError::new("BAD_PARAMS", "未知的服务操作"));
    }
    let id = operation_id(&action);
    emit_operation(&app, &id, &action, "authorizing", "等待管理员授权…", None);
    let binary_result = if action == "install" {
        install_source(&app)
    } else {
        service_binary()
    };
    let binary = match binary_result {
        Ok(binary) => binary,
        Err(error) => {
            emit_operation(
                &app,
                &id,
                &action,
                "failed",
                &error.message,
                Some(error.clone()),
            );
            return Err(error);
        }
    };
    let command = format!(
        "{} daemon {}",
        shell_quote(&binary.to_string_lossy()),
        shell_quote(&action)
    );
    let result = tauri::async_runtime::spawn_blocking(move || run_admin(&command))
        .await
        .map_err(|error| UiError::new("SERVICE_TASK_FAILED", "服务任务异常退出").with_detail(error.to_string()))?;
    if let Err(error) = result {
        emit_operation(
            &app,
            &id,
            &action,
            if error.code == "ADMIN_CANCELLED" { "cancelled" } else { "failed" },
            &error.message,
            Some(error.clone()),
        );
        return Err(error);
    }
    emit_operation(
        &app,
        &id,
        &action,
        "verifying",
        if matches!(action.as_str(), "stop" | "restart") {
            "正在验证卷已安全卸载和服务状态…"
        } else {
            "正在验证服务状态…"
        },
        None,
    );
    let verify_action = action.clone();
    let verification = tauri::async_runtime::spawn_blocking(move || {
        verify_service_action(&verify_action)
    })
        .await
        .map_err(|error| UiError::new("VERIFY_FAILED", "无法验证服务状态").with_detail(error.to_string()))?;
    if let Err(error) = verification {
        emit_operation(
            &app,
            &id,
            &action,
            "failed",
            &error.message,
            Some(error.clone()),
        );
        return Err(error);
    }
    let snapshot = publish_snapshot(&app);
    let message = match action.as_str() {
        "install" => "后台服务已安装并启动",
        "start" => "后台服务已启动",
        "stop" => "后台服务已安全停止",
        "restart" => "后台服务已安全重启",
        "uninstall" => "后台服务已卸载，用户数据已保留",
        _ => "操作完成",
    };
    emit_operation(&app, &id, &action, "succeeded", message, None);
    Ok(ServiceActionResult {
        action,
        service: snapshot.service.clone(),
        snapshot,
    })
}

// ---------- cached, read-only tray ----------

fn build_tray_menu(app: &AppHandle, snapshot: &AppSnapshot) -> Result<Menu<tauri::Wry>, tauri::Error> {
    let menu = Menu::new(app)?;
    let service_label = if snapshot.service["running"].as_bool().unwrap_or(false) {
        "后台服务：运行中"
    } else if snapshot.service["installed"].as_bool().unwrap_or(false) {
        "后台服务：已停止"
    } else {
        "后台服务：未安装"
    };
    menu.append(&MenuItem::with_id(app, "service_status", service_label, false, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(
        app,
        "auto_status",
        if snapshot.auto_mount_mode == "active" { "自动挂载：运行中" } else { "自动挂载：已暂停" },
        false,
        None::<&str>,
    )?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    if snapshot.sessions.is_empty() {
        menu.append(&MenuItem::with_id(app, "no_sessions", "无挂载中的卷", false, None::<&str>)?)?;
    } else {
        for session in &snapshot.sessions {
            let id = session["session_id"].as_str().unwrap_or_default();
            let mountpoint = first_mountpoint(session).unwrap_or_else(|| "未知挂载点".to_string());
            menu.append(&MenuItem::with_id(
                app,
                format!("session-{id}"),
                format!("{} — {mountpoint}", partition_label(session)),
                true,
                None::<&str>,
            )?)?;
        }
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "open", "打开 EDP USB Client", true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?)?;
    Ok(menu)
}

fn setup_tray(app: &AppHandle) -> tauri::Result<()> {
    let snapshot = app.state::<UiStateCoordinator>().current();
    let tray = TrayIconBuilder::new()
        .icon(app.default_window_icon().cloned().unwrap())
        .menu(&build_tray_menu(app, &snapshot)?)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app.clone()),
            "quit" => app.exit(0),
            id if id.starts_with("session-") => {
                let session_id = id.trim_start_matches("session-");
                let snapshot = app.state::<UiStateCoordinator>().current();
                if let Some(path) = snapshot
                    .sessions
                    .iter()
                    .find(|session| session["session_id"] == session_id)
                    .and_then(first_mountpoint)
                {
                    let _ = std::process::Command::new("open").arg(path).spawn();
                }
            }
            _ => {}
        })
        .build(app)?;
    *app.state::<TrayState>().0.lock().unwrap() = Some(tray);
    Ok(())
}

fn rebuild_tray(app: &AppHandle, snapshot: &AppSnapshot) -> tauri::Result<()> {
    if let Some(tray) = app.state::<TrayState>().0.lock().unwrap().as_ref() {
        tray.set_menu(Some(build_tray_menu(app, snapshot)?))?;
    }
    Ok(())
}

// ---------- daemon event bridge ----------

fn spawn_subscriber(app: AppHandle) {
    std::thread::spawn(move || {
        let socket = Rpc::socket_path();
        loop {
            let mut client = match edp_proto::Client::connect(&socket) {
                Ok(client) => client,
                Err(_) => {
                    std::thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };
            let app_for_event = app.clone();
            let _ = client.subscribe(move |event| {
                let _ = app_for_event.emit(RAW_EVENT, event.clone());
                schedule_snapshot_refresh(app_for_event.clone());
                let title = match event.event.as_str() {
                    edp_proto::event::MOUNTED => Some("EDP 卷已挂载"),
                    edp_proto::event::UNMOUNTED => Some("EDP 卷已卸载"),
                    edp_proto::event::PASSWORD_NEEDED => Some("已授权设备需要密码"),
                    edp_proto::event::DEVICE_NEEDS_SETUP => Some("发现待配置 EDP 设备"),
                    edp_proto::event::MOUNT_FAILED => Some("EDP 卷挂载失败"),
                    _ => None,
                };
                if let Some(title) = title {
                    let body = first_mountpoint(&event.data).unwrap_or_else(|| event.event.clone());
                    let _ = app_for_event.notification().builder().title(title).body(body).show();
                }
            });
            std::thread::sleep(Duration::from_secs(2));
        }
    });
}

fn spawn_health_check(app: AppHandle) {
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(5));
        let current = app.state::<UiStateCoordinator>().current();
        let service = service_status_impl().unwrap_or_else(|_| json!({}));
        let changed = ["installed", "running", "enabled", "online"]
            .iter()
            .any(|key| current.service[*key] != service[*key]);
        if changed {
            let _ = publish_snapshot(&app);
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .manage(Rpc::new())
        .manage(UiStateCoordinator::default())
        .manage(TrayState(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            get_app_snapshot,
            refresh_app_snapshot,
            set_auto_mount_mode,
            set_device_policy,
            mount_partition,
            unmount_session,
            save_credential,
            delete_credential,
            get_diagnostics,
            run_service_action,
            open_in_finder,
            show_main,
        ])
        .setup(|app| {
            let _ = app.handle().set_activation_policy(tauri::ActivationPolicy::Accessory);
            setup_tray(app.handle())?;
            spawn_subscriber(app.handle().clone());
            spawn_health_check(app.handle().clone());
            let app_for_snapshot = app.handle().clone();
            std::thread::spawn(move || {
                let _ = publish_snapshot(&app_for_snapshot);
            });
            if let Some(window) = app.get_webview_window("main") {
                let window_for_event = window.clone();
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        let _ = window_for_event.hide();
                    }
                });
                let _ = window.show();
                let _ = window.set_focus();
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::Reopen { .. } = event {
                show_main(app.clone());
                let _ = publish_snapshot(app);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installed_service_binary_always_wins() {
        let root = std::env::temp_dir().join(format!("edp-ui-test-{}", std::process::id()));
        let installed = root.join("installed-usbcore");
        let workspace = root.join("workspace-usbcore");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(&installed, b"installed").unwrap();
        std::fs::write(&workspace, b"workspace").unwrap();
        assert_eq!(
            resolve_service_binary(&installed, std::slice::from_ref(&workspace)),
            Some(installed.clone())
        );
        std::fs::remove_file(installed).unwrap();
        std::fs::remove_file(workspace).unwrap();
        std::fs::remove_dir(root).unwrap();
    }

    #[test]
    fn release_build_never_uses_workspace_fallback() {
        if cfg!(debug_assertions) {
            return;
        }
        assert_eq!(
            resolve_service_binary(
                Path::new("/definitely/missing/installed-usbcore"),
                &[PathBuf::from(env!("CARGO_MANIFEST_DIR"))],
            ),
            None
        );
    }

    #[test]
    fn service_action_verification_requires_the_expected_state() {
        let running = json!({ "installed": true, "running": true, "enabled": true });
        let stopped = json!({ "installed": true, "running": false, "enabled": false });
        let removed = json!({ "installed": false, "running": false, "enabled": false });
        assert!(service_action_complete("start", &running));
        assert!(!service_action_complete("start", &stopped));
        assert!(service_action_complete("stop", &stopped));
        assert!(!service_action_complete("stop", &running));
        assert!(service_action_complete("uninstall", &removed));
    }
}
