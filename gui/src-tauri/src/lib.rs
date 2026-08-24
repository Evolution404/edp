//! EDP USB Vault UI v2 Tauri backend.
//!
//! The webview and tray consume one cached snapshot. Daemon events are debounced
//! into snapshot refreshes so the UI never maintains an independent truth.

mod service_management;

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const SOCKET_PATH: &str = "/var/run/com.edp.usbvault.daemon.sock";
const LEGACY_USB_CORE: &str = "/usr/local/libexec/usbcore";
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
        client
            .call(method, params)
            .map_err(|error| error.to_string())
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
                "installed": false,
                "embedded": false,
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
    refresh_generation: AtomicU64,
    refresh_worker_running: AtomicBool,
}

impl Default for UiStateCoordinator {
    fn default() -> Self {
        Self {
            revision: AtomicU64::new(0),
            snapshot: Mutex::new(AppSnapshot::default()),
            refresh_lock: Mutex::new(()),
            refresh_generation: AtomicU64::new(0),
            refresh_worker_running: AtomicBool::new(false),
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
                "installed": false,
                "embedded": false,
                "running": false,
                "enabled": false,
                "online": false,
                "error": error.message,
            })
        });

        let (daemon, auto_mount_mode, devices, sessions, credentials, last_error) = match rpc
            .call(edp_proto::method::STATUS, json!({}))
        {
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

#[derive(Debug, Clone, Hash)]
enum TrayAction {
    Mount {
        disk: String,
        device_id: String,
        partition_type: u32,
    },
    Unmount {
        session_id: String,
        partition_type: u32,
    },
    OpenFinder {
        path: String,
    },
}

#[derive(Default)]
pub struct TrayState {
    icon: Mutex<Option<TrayIcon>>,
    actions: Mutex<HashMap<String, TrayAction>>,
}

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

fn publish_snapshot(app: &AppHandle) -> AppSnapshot {
    let snapshot = app.state::<UiStateCoordinator>().refresh();
    let _ = app.emit(SNAPSHOT_EVENT, snapshot.clone());
    let _ = rebuild_tray(app, &snapshot);
    snapshot
}

fn schedule_snapshot_refresh(app: AppHandle) {
    let coordinator = app.state::<UiStateCoordinator>();
    coordinator
        .refresh_generation
        .fetch_add(1, Ordering::SeqCst);
    if coordinator
        .refresh_worker_running
        .swap(true, Ordering::SeqCst)
    {
        return;
    }
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(150));
        let handled_generation = app
            .state::<UiStateCoordinator>()
            .refresh_generation
            .load(Ordering::SeqCst);
        let _ = publish_snapshot(&app);

        let coordinator = app.state::<UiStateCoordinator>();
        if coordinator.refresh_generation.load(Ordering::SeqCst) != handled_generation {
            continue;
        }
        coordinator
            .refresh_worker_running
            .store(false, Ordering::SeqCst);
        if coordinator.refresh_generation.load(Ordering::SeqCst) == handled_generation {
            break;
        }
        if coordinator
            .refresh_worker_running
            .swap(true, Ordering::SeqCst)
        {
            break;
        }
    });
}

async fn blocking_ui_task<T, F>(task: F) -> Result<T, UiError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, UiError> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(task)
        .await
        .map_err(|error| {
            UiError::new("BACKGROUND_TASK_FAILED", "后台操作异常退出")
                .with_detail(error.to_string())
        })?
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
async fn get_app_snapshot(app: AppHandle) -> Result<AppSnapshot, UiError> {
    let current = app.state::<UiStateCoordinator>().current();
    if current.revision != 0 {
        return Ok(current);
    }
    blocking_ui_task(move || Ok(publish_snapshot(&app))).await
}

#[tauri::command]
async fn refresh_app_snapshot(app: AppHandle) -> Result<AppSnapshot, UiError> {
    blocking_ui_task(move || Ok(publish_snapshot(&app))).await
}

#[tauri::command]
async fn set_auto_mount_mode(app: AppHandle, mode: String) -> Result<AppSnapshot, UiError> {
    if !matches!(mode.as_str(), "active" | "paused") {
        return Err(UiError::new("BAD_PARAMS", "自动挂载状态无效"));
    }
    blocking_ui_task(move || {
        Rpc::new()
            .call(
                edp_proto::method::AUTO_MOUNT_SET_MODE,
                json!({ "mode": mode }),
            )
            .map_err(|message| {
                UiError::new("RPC_FAILED", "无法更新自动挂载状态").with_detail(message)
            })?;
        Ok(publish_snapshot(&app))
    })
    .await
}

#[tauri::command]
async fn set_device_policy(app: AppHandle, policy: Value) -> Result<AppSnapshot, UiError> {
    blocking_ui_task(move || {
        Rpc::new()
            .call(edp_proto::method::DEVICES_POLICY_SET, policy)
            .map_err(|message| {
                UiError::new("RPC_FAILED", "无法保存分区自动挂载设置").with_detail(message)
            })?;
        Ok(publish_snapshot(&app))
    })
    .await
}

#[tauri::command]
async fn mount_partition(
    app: AppHandle,
    disk: String,
    device_id: String,
    partition_type: u32,
) -> Result<AppSnapshot, UiError> {
    blocking_ui_task(move || {
        Rpc::new()
            .call(
                edp_proto::method::MOUNT,
                json!({ "disk": disk, "device_id": device_id, "partition_type": partition_type }),
            )
            .map_err(|message| UiError::new("MOUNT_FAILED", "挂载失败").with_detail(message))?;
        Ok(publish_snapshot(&app))
    })
    .await
}

#[tauri::command]
async fn unmount_session(
    app: AppHandle,
    session_id: String,
    force: Option<bool>,
) -> Result<AppSnapshot, UiError> {
    blocking_ui_task(move || {
        Rpc::new()
            .call(
                edp_proto::method::UNMOUNT,
                json!({ "session_id": session_id, "force": force.unwrap_or(false) }),
            )
            .map_err(|message| UiError::new("UNMOUNT_FAILED", "卸载失败").with_detail(message))?;
        Ok(publish_snapshot(&app))
    })
    .await
}

#[tauri::command]
async fn save_credential(app: AppHandle, input: CredentialInput) -> Result<AppSnapshot, UiError> {
    if input.password.is_empty() {
        return Err(UiError::new("BAD_PARAMS", "密码不能为空"));
    }
    blocking_ui_task(move || {
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
        .map_err(|message| {
            UiError::new("CREDENTIAL_SAVE_FAILED", "无法保存凭据").with_detail(message)
        })?;
        Ok(publish_snapshot(&app))
    })
    .await
}

#[tauri::command]
async fn delete_credential(app: AppHandle, id: String) -> Result<AppSnapshot, UiError> {
    blocking_ui_task(move || {
        Rpc::new()
            .call(edp_proto::method::KEYS_RM, json!({ "id": id }))
            .map_err(|message| {
                UiError::new("CREDENTIAL_DELETE_FAILED", "无法删除凭据").with_detail(message)
            })?;
        Ok(publish_snapshot(&app))
    })
    .await
}

#[tauri::command]
async fn get_diagnostics(app: AppHandle) -> Result<Value, UiError> {
    blocking_ui_task(move || {
        let logs = Rpc::new()
            .call(edp_proto::method::LOGS_READ, json!({ "lines": 200 }))
            .unwrap_or_else(|error| json!({ "logs": [], "error": error }));
        let performance = Rpc::new()
            .call(edp_proto::method::PERFORMANCE_SNAPSHOT, json!({}))
            .unwrap_or_else(|error| json!({ "sessions": [], "error": error }));
        Ok(json!({
            "snapshot": app.state::<UiStateCoordinator>().current(),
            "logs": logs["logs"],
            "performance": performance,
        }))
    })
    .await
}

const FINDER_WINDOW_SCRIPT: &str = r#"
on run argv
  if (count of argv) is not 1 then error "missing folder path"
  set targetFolder to POSIX file (item 1 of argv) as alias
  tell application "Finder"
    activate
    set targetWindow to make new Finder window
    set target of targetWindow to targetFolder
    set toolbar visible of targetWindow to true
    if sidebar width of targetWindow < 160 then set sidebar width of targetWindow to 180
  end tell
end run
"#;

fn finder_window_command(path: &str) -> std::process::Command {
    let mut command = std::process::Command::new("/usr/bin/osascript");
    command.args(["-e", FINDER_WINDOW_SCRIPT, "--", path]);
    command
}

#[tauri::command]
async fn open_in_finder(path: String) -> Result<(), UiError> {
    if path.is_empty() {
        return Err(UiError::new("BAD_PARAMS", "没有可打开的挂载点"));
    }
    if !Path::new(&path).is_dir() {
        return Err(UiError::new("MOUNTPOINT_GONE", "挂载点已不可用").with_detail(path));
    }
    blocking_ui_task(move || {
        let output = finder_window_command(&path).output().map_err(|error| {
            UiError::new("OPEN_FAILED", "无法在 Finder 中打开").with_detail(error.to_string())
        })?;
        if output.status.success() {
            return Ok(());
        }
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(UiError::new("OPEN_FAILED", "无法创建标准 Finder 窗口").with_detail(detail))
    })
    .await
}

#[tauri::command]
fn show_main(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

// ---------- service lifecycle ----------

fn legacy_service_installed() -> bool {
    Path::new(LEGACY_USB_CORE).exists()
        || Path::new("/Library/LaunchDaemons/com.edp.usbcore.plist").exists()
}

fn service_status_impl() -> Result<Value, UiError> {
    use service_management::Status;
    let registration = service_management::status();
    let online = Rpc::new()
        .call(edp_proto::method::STATUS, json!({}))
        .is_ok();
    Ok(json!({
        "installed": matches!(registration, Status::Enabled | Status::RequiresApproval),
        "embedded": !matches!(registration, Status::NotFound),
        "enabled": matches!(registration, Status::Enabled),
        "requires_approval": matches!(registration, Status::RequiresApproval),
        "running": online,
        "online": online,
        "legacy_installed": legacy_service_installed(),
    }))
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
        .map_err(|error| {
            UiError::new("ADMIN_FAILED", "无法请求管理员授权").with_detail(error.to_string())
        })?;
    if output.status.success() {
        return Ok(());
    }
    let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if detail.contains("User canceled") || detail.contains("-128") || detail.contains("用户已取消")
    {
        return Err(UiError::new("ADMIN_CANCELLED", "已取消管理员授权"));
    }
    Err(UiError::new("SERVICE_CONTROL_FAILED", "后台服务操作失败").with_detail(detail))
}

fn cleanup_legacy_installation() -> Result<(), UiError> {
    if !legacy_service_installed() && !Path::new("/var/db/edp-usbcore").exists() {
        return Ok(());
    }
    let script = format!(
        "if [ -x {binary} ]; then {binary} daemon uninstall; \
         elif /bin/launchctl print system/com.edp.usbcore >/dev/null 2>&1; then \
         echo '旧后台服务仍在运行但卸载程序缺失' >&2; exit 42; fi; \
         /bin/rm -f /Library/LaunchDaemons/com.edp.usbcore.plist \
         /usr/local/bin/usbcore {binary} /var/run/edp-usbcore.sock; \
         /bin/rm -rf /var/db/edp-usbcore",
        binary = LEGACY_USB_CORE,
    );
    run_admin(&script)
}

fn purge_embedded_data() -> Result<(), UiError> {
    run_admin(
        "/bin/rm -f /var/run/com.edp.usbvault.daemon.sock; \
         /bin/rm -rf /var/db/com.edp.usbvault",
    )
}

fn prepare_daemon_stop(purge_data: bool) -> Result<(), UiError> {
    let mut client = edp_proto::Client::connect(SOCKET_PATH).map_err(|error| {
        UiError::new("DAEMON_OFFLINE", "后台服务未连接").with_detail(error.to_string())
    })?;
    client
        .call(
            edp_proto::method::DAEMON_SHUTDOWN,
            json!({ "exit": false, "purge_data": purge_data }),
        )
        .map(|_| ())
        .map_err(|error| {
            UiError::new("SAFE_STOP_FAILED", "加密卷安全卸载失败，服务保持运行")
                .with_detail(error.to_string())
        })
}

fn prepare_daemon_restart() -> Result<(), UiError> {
    let old_uptime = Rpc::new()
        .call(edp_proto::method::STATUS, json!({}))
        .ok()
        .and_then(|status| status["uptime_s"].as_u64())
        .unwrap_or(u64::MAX);
    let mut client = edp_proto::Client::connect(SOCKET_PATH).map_err(|error| {
        UiError::new("DAEMON_OFFLINE", "后台服务未连接").with_detail(error.to_string())
    })?;
    client
        .call(
            edp_proto::method::DAEMON_SHUTDOWN,
            json!({ "exit": true, "purge_data": false }),
        )
        .map_err(|error| {
            UiError::new("SAFE_RESTART_FAILED", "加密卷安全卸载失败，服务保持运行")
                .with_detail(error.to_string())
        })?;

    for _ in 0..100 {
        std::thread::sleep(Duration::from_millis(100));
        if let Ok(status) = Rpc::new().call(edp_proto::method::STATUS, json!({})) {
            let uptime = status["uptime_s"].as_u64().unwrap_or(u64::MAX);
            if uptime < old_uptime {
                return Ok(());
            }
        }
    }
    Err(UiError::new(
        "RESTART_TIMEOUT",
        "后台服务退出后未被 launchd 重新拉起",
    ))
}

fn service_action_complete(action: &str, status: &Value) -> bool {
    let installed = status["installed"].as_bool().unwrap_or(false);
    let running = status["running"].as_bool().unwrap_or(false);
    let enabled = status["enabled"].as_bool().unwrap_or(false);
    let requires_approval = status["requires_approval"].as_bool().unwrap_or(false);
    match action {
        "install" | "start" | "restart" => installed && (requires_approval || (running && enabled)),
        "stop" => !installed && !running && !enabled,
        "uninstall" => !installed && !running,
        _ => false,
    }
}

fn parse_launchd_failure(output: &str) -> Option<String> {
    if output.contains("last exit reason = OS_REASON_DYLD") {
        return Some(
            "后台进程启动时无法加载 macFUSE 运行库。请更新或重新安装 EDP USB Vault 与 macFUSE。"
                .to_string(),
        );
    }
    if output.contains("successive crashes") || output.contains("job state = exited") {
        return Some(
            "后台进程被 launchd 反复启动后异常退出，请打开“活动 → 诊断详情”查看系统错误。"
                .to_string(),
        );
    }
    None
}

fn launchd_failure_detail() -> Option<String> {
    let output = std::process::Command::new("/bin/launchctl")
        .args(["print", "system/com.edp.usbvault.daemon.v2"])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    parse_launchd_failure(&format!("{stdout}\n{stderr}"))
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
    let detail = launchd_failure_detail().unwrap_or_else(|| {
        last_status
            .map(|status| status.to_string())
            .unwrap_or_else(|| "无法读取服务状态".to_string())
    });
    Err(UiError::new("VERIFY_TIMEOUT", "后台服务未能启动").with_detail(detail))
}

#[tauri::command]
async fn run_service_action(
    app: AppHandle,
    action: String,
) -> Result<ServiceActionResult, UiError> {
    if !matches!(
        action.as_str(),
        "install" | "start" | "stop" | "restart" | "uninstall"
    ) {
        return Err(UiError::new("BAD_PARAMS", "未知的服务操作"));
    }
    let id = operation_id(&action);
    emit_operation(
        &app,
        &id,
        &action,
        "authorizing",
        match action.as_str() {
            "restart" => "正在安全卸载并重启后台服务…",
            "stop" | "uninstall" => "正在安全卸载加密卷…",
            _ => "正在更新 macOS 后台项目…",
        },
        None,
    );
    let current = service_status_impl()?;
    let installed = current["installed"].as_bool().unwrap_or(false);
    let running = current["running"].as_bool().unwrap_or(false);
    let action_for_task = action.clone();
    let result = tauri::async_runtime::spawn_blocking(move || -> Result<(), UiError> {
        match action_for_task.as_str() {
            "install" | "start" => {
                cleanup_legacy_installation()?;
                // SMAppService 会记住注册时的父 App 版本。应用覆盖升级后，
                // 单纯再次 register 是 no-op，launchd 仍会以旧版本校验并报 EX_CONFIG。
                if installed {
                    service_management::unregister().map_err(|message| {
                        UiError::new("SERVICE_REFRESH_FAILED", "无法更新后台服务注册")
                            .with_detail(message)
                    })?;
                    std::thread::sleep(Duration::from_millis(300));
                }
                service_management::register().map_err(|message| {
                    UiError::new("SERVICE_REGISTER_FAILED", "无法启用嵌入式后台服务")
                        .with_detail(message)
                })
            }
            "stop" => {
                if running {
                    prepare_daemon_stop(false)?;
                }
                service_management::unregister().map_err(|message| {
                    UiError::new("SERVICE_UNREGISTER_FAILED", "无法停用嵌入式后台服务")
                        .with_detail(message)
                })
            }
            "restart" => {
                if running {
                    prepare_daemon_restart()?;
                }
                Ok(())
            }
            "uninstall" => {
                if running {
                    prepare_daemon_stop(true)?;
                }
                service_management::unregister().map_err(|message| {
                    UiError::new("SERVICE_UNREGISTER_FAILED", "无法注销嵌入式后台服务")
                        .with_detail(message)
                })?;
                cleanup_legacy_installation()?;
                purge_embedded_data()
            }
            _ => unreachable!(),
        }
    })
    .await
    .map_err(|error| {
        UiError::new("SERVICE_TASK_FAILED", "服务任务异常退出").with_detail(error.to_string())
    })?;
    if let Err(error) = result {
        emit_operation(
            &app,
            &id,
            &action,
            if error.code == "ADMIN_CANCELLED" {
                "cancelled"
            } else {
                "failed"
            },
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
    let verification =
        tauri::async_runtime::spawn_blocking(move || verify_service_action(&verify_action))
            .await
            .map_err(|error| {
                UiError::new("VERIFY_FAILED", "无法验证服务状态").with_detail(error.to_string())
            })?;
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
    let approval_required = snapshot.service["requires_approval"]
        .as_bool()
        .unwrap_or(false);
    if approval_required {
        service_management::open_login_items();
    }
    let message = match action.as_str() {
        "install" | "start" if approval_required => "请在系统设置中允许 EDP USB Vault 后台项目",
        "install" => "嵌入式后台服务已启用",
        "start" => "嵌入式后台服务已启动",
        "stop" => "后台服务已安全停止",
        "restart" => "后台服务已安全重启",
        "uninstall" => "后台服务与应用数据已完全清理",
        _ => "操作完成",
    };
    emit_operation(&app, &id, &action, "succeeded", message, None);
    Ok(ServiceActionResult {
        action,
        service: snapshot.service.clone(),
        snapshot,
    })
}

#[tauri::command]
fn open_login_items_settings() {
    service_management::open_login_items();
}

// ---------- cached tray ----------

fn partition_type_label(partition_type: u32) -> &'static str {
    match partition_type {
        2 => "交换区",
        4 => "保密区",
        _ => "EDP 卷",
    }
}

fn tray_action_item(
    app: &AppHandle,
    actions: &mut HashMap<String, TrayAction>,
    label: String,
    action: TrayAction,
) -> Result<MenuItem<tauri::Wry>, tauri::Error> {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    action.hash(&mut hasher);
    let id = format!("tray-action-{:016x}", hasher.finish());
    actions.insert(id.clone(), action);
    MenuItem::with_id(app, id, label, true, None::<&str>)
}

fn mounted_session<'a>(
    snapshot: &'a AppSnapshot,
    device_id: &str,
    partition_type: u32,
) -> Option<&'a Value> {
    snapshot.sessions.iter().find(|session| {
        session["device_id"].as_str() == Some(device_id)
            && session["partition"]["partition_type"].as_u64() == Some(partition_type as u64)
    })
}

fn has_credential(snapshot: &AppSnapshot, device_id: &str, partition_type: u32) -> bool {
    snapshot.credentials.iter().any(|credential| {
        credential["device_id"].as_str() == Some(device_id)
            && credential["partition_type"].as_u64() == Some(partition_type as u64)
    })
}

fn build_tray_menu(
    app: &AppHandle,
    snapshot: &AppSnapshot,
) -> Result<Menu<tauri::Wry>, tauri::Error> {
    let menu = Menu::new(app)?;
    let service_label = if snapshot.service["running"].as_bool().unwrap_or(false) {
        "后台服务：运行中"
    } else if snapshot.service["enabled"].as_bool().unwrap_or(false) {
        "后台服务：异常"
    } else if snapshot.service["installed"].as_bool().unwrap_or(false) {
        "后台服务：已停止"
    } else {
        "后台服务：未安装"
    };
    menu.append(&MenuItem::with_id(
        app,
        "service_status",
        service_label,
        false,
        None::<&str>,
    )?)?;
    menu.append(&MenuItem::with_id(
        app,
        "auto_status",
        if snapshot.auto_mount_mode == "active" {
            "自动挂载：运行中"
        } else {
            "自动挂载：已暂停"
        },
        false,
        None::<&str>,
    )?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;

    let connected_devices: Vec<&Value> = snapshot
        .devices
        .iter()
        .filter(|device| device["connected"].as_bool().unwrap_or(false))
        .collect();
    let mut actions = HashMap::new();
    if connected_devices.is_empty() {
        menu.append(&MenuItem::with_id(
            app,
            "no_devices",
            "未检测到外置磁盘",
            false,
            None::<&str>,
        )?)?;
    } else {
        for (device_index, device) in connected_devices.into_iter().enumerate() {
            let media_name = device["policy"]["label"]
                .as_str()
                .or_else(|| device["media_name"].as_str())
                .filter(|value| !value.is_empty())
                .unwrap_or("外置磁盘");
            let submenu =
                Submenu::with_id(app, format!("tray-device-{device_index}"), media_name, true)?;
            let kind = device["kind"].as_str().unwrap_or("unknown");
            let device_id = device["device_id"].as_str().unwrap_or_default();
            let disk = device["rbsd"].as_str().unwrap_or_default();

            if kind != "edp" || device_id.is_empty() || disk.is_empty() {
                let text = if kind == "ordinary" {
                    "普通 U 盘，本应用不会操作"
                } else {
                    "正在只读识别设备…"
                };
                submenu.append(&MenuItem::with_id(
                    app,
                    format!("tray-device-{device_index}-info"),
                    text,
                    false,
                    None::<&str>,
                )?)?;
                menu.append(&submenu)?;
                continue;
            }

            for partition_type in [2_u32, 4_u32] {
                let label = partition_type_label(partition_type);
                if let Some(session) = mounted_session(snapshot, device_id, partition_type) {
                    let session_id = session["session_id"].as_str().unwrap_or_default();
                    submenu.append(&tray_action_item(
                        app,
                        &mut actions,
                        format!("卸载{label}"),
                        TrayAction::Unmount {
                            session_id: session_id.to_string(),
                            partition_type,
                        },
                    )?)?;
                    if let Some(path) = first_mountpoint(session) {
                        submenu.append(&tray_action_item(
                            app,
                            &mut actions,
                            format!("在 Finder 中打开{label}"),
                            TrayAction::OpenFinder { path },
                        )?)?;
                    }
                } else if has_credential(snapshot, device_id, partition_type) {
                    submenu.append(&tray_action_item(
                        app,
                        &mut actions,
                        format!("挂载{label}"),
                        TrayAction::Mount {
                            disk: disk.to_string(),
                            device_id: device_id.to_string(),
                            partition_type,
                        },
                    )?)?;
                } else {
                    submenu.append(&MenuItem::with_id(
                        app,
                        format!("tray-device-{device_index}-missing-{partition_type}"),
                        format!("{label} — 未配置密码"),
                        false,
                        None::<&str>,
                    )?)?;
                }
            }
            menu.append(&submenu)?;
        }
    }
    *app.state::<TrayState>().actions.lock().unwrap() = actions;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(
        app,
        "open",
        "打开 EDP USB Vault",
        true,
        None::<&str>,
    )?)?;
    menu.append(&MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?)?;
    Ok(menu)
}

fn run_tray_action(app: AppHandle, action: TrayAction) {
    std::thread::spawn(move || {
        let (action_name, message) = match &action {
            TrayAction::Mount { partition_type, .. } => (
                "tray-mount",
                format!("正在挂载{}…", partition_type_label(*partition_type)),
            ),
            TrayAction::Unmount { partition_type, .. } => (
                "tray-unmount",
                format!("正在卸载{}…", partition_type_label(*partition_type)),
            ),
            TrayAction::OpenFinder { .. } => ("tray-finder", "正在打开 Finder…".to_string()),
        };
        let id = operation_id(action_name);
        emit_operation(&app, &id, action_name, "verifying", &message, None);
        let result: Result<String, UiError> = match action {
            TrayAction::Mount {
                disk,
                device_id,
                partition_type,
            } => Rpc::new()
                .call(
                    edp_proto::method::MOUNT,
                    json!({
                        "disk": disk,
                        "device_id": device_id,
                        "partition_type": partition_type,
                    }),
                )
                .map(|_| format!("{}已挂载", partition_type_label(partition_type)))
                .map_err(|error| UiError::new("MOUNT_FAILED", "托盘挂载失败").with_detail(error)),
            TrayAction::Unmount {
                session_id,
                partition_type,
            } => Rpc::new()
                .call(
                    edp_proto::method::UNMOUNT,
                    json!({ "session_id": session_id, "force": false }),
                )
                .map(|_| format!("{}已卸载", partition_type_label(partition_type)))
                .map_err(|error| UiError::new("UNMOUNT_FAILED", "托盘卸载失败").with_detail(error)),
            TrayAction::OpenFinder { path } => finder_window_command(&path)
                .output()
                .map_err(|error| {
                    UiError::new("OPEN_FAILED", "无法打开 Finder").with_detail(error.to_string())
                })
                .and_then(|output| {
                    if output.status.success() {
                        Ok("已打开 Finder".to_string())
                    } else {
                        Err(UiError::new("OPEN_FAILED", "无法打开 Finder").with_detail(
                            String::from_utf8_lossy(&output.stderr).trim().to_string(),
                        ))
                    }
                }),
        };
        let _ = publish_snapshot(&app);
        match result {
            Ok(done) => {
                emit_operation(&app, &id, action_name, "succeeded", &done, None);
                let _ = app.notification().builder().title(&done).show();
            }
            Err(error) => {
                emit_operation(
                    &app,
                    &id,
                    action_name,
                    "failed",
                    &error.message,
                    Some(error.clone()),
                );
                let body = error.detail.as_deref().unwrap_or(&error.message);
                let _ = app
                    .notification()
                    .builder()
                    .title(&error.message)
                    .body(body)
                    .show();
            }
        }
    });
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
            id if id.starts_with("tray-action-") => {
                let action = app
                    .state::<TrayState>()
                    .actions
                    .lock()
                    .unwrap()
                    .get(id)
                    .cloned();
                if let Some(action) = action {
                    run_tray_action(app.clone(), action);
                }
            }
            _ => {}
        })
        .build(app)?;
    *app.state::<TrayState>().icon.lock().unwrap() = Some(tray);
    Ok(())
}

fn rebuild_tray(app: &AppHandle, snapshot: &AppSnapshot) -> tauri::Result<()> {
    if let Some(tray) = app.state::<TrayState>().icon.lock().unwrap().as_ref() {
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
            // The daemon may discover and mount an already-connected device before this
            // subscriber finishes reconnecting (notably just after enabling the service).
            // Refresh once on every successful connection so those state transitions are
            // visible even when their events happened before subscribe was established.
            schedule_snapshot_refresh(app.clone());
            let app_for_convergence = app.clone();
            std::thread::spawn(move || {
                // Mounting through macFUSE can finish after the subscriber connects. A
                // second, infrequent refresh closes that startup-only race without
                // bringing back the old periodic full-state polling.
                std::thread::sleep(Duration::from_secs(4));
                schedule_snapshot_refresh(app_for_convergence);
            });
            let app_for_event = app.clone();
            let _ = client.subscribe(move |event| {
                let _ = app_for_event.emit(RAW_EVENT, event.clone());
                schedule_snapshot_refresh(app_for_event.clone());
                let title = match event.event.as_str() {
                    edp_proto::event::MOUNTED => Some("EDP 卷已挂载"),
                    edp_proto::event::UNMOUNTED => Some("EDP 卷已卸载"),
                    edp_proto::event::PASSWORD_NEEDED => Some("已选择的自动挂载分区需要密码"),
                    edp_proto::event::DEVICE_NEEDS_SETUP => Some("发现待配置 EDP 设备"),
                    edp_proto::event::MOUNT_FAILED => Some("EDP 卷挂载失败"),
                    _ => None,
                };
                if let Some(title) = title {
                    let body = first_mountpoint(&event.data).unwrap_or_else(|| event.event.clone());
                    let _ = app_for_event
                        .notification()
                        .builder()
                        .title(title)
                        .body(body)
                        .show();
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
        let service_changed = ["installed", "running", "enabled", "online"]
            .iter()
            .any(|key| current.service[*key] != service[*key]);
        let daemon = Rpc::new().call(edp_proto::method::STATUS, json!({})).ok();
        let daemon_changed = match (&current.daemon, &daemon) {
            (Some(previous), Some(latest)) => {
                previous["mounted_sessions"] != latest["mounted_sessions"]
                    || previous["auto_mount_mode"] != latest["auto_mount_mode"]
            }
            (None, None) => false,
            _ => true,
        };
        if service_changed || daemon_changed {
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
        .manage(TrayState::default())
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
            open_login_items_settings,
            show_main,
        ])
        .setup(|app| {
            let _ = app
                .handle()
                .set_activation_policy(tauri::ActivationPolicy::Accessory);
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
    fn service_action_verification_requires_the_expected_state() {
        let running = json!({ "installed": true, "running": true, "enabled": true });
        let approval = json!({
            "installed": true,
            "running": false,
            "enabled": false,
            "requires_approval": true
        });
        let stopped = json!({ "installed": false, "running": false, "enabled": false });
        let removed = json!({ "installed": false, "running": false, "enabled": false });
        assert!(service_action_complete("start", &running));
        assert!(service_action_complete("start", &approval));
        assert!(!service_action_complete("start", &stopped));
        assert!(service_action_complete("stop", &stopped));
        assert!(!service_action_complete("stop", &running));
        assert!(service_action_complete("uninstall", &removed));
    }

    #[test]
    fn launchd_dyld_failure_has_actionable_message() {
        let detail = parse_launchd_failure(
            "runs = 18\nsuccessive crashes = 18\nlast exit reason = OS_REASON_DYLD\njob state = exited",
        )
        .expect("dyld failure should be recognized");
        assert!(detail.contains("无法加载 macFUSE 运行库"));
        assert!(detail.contains("EDP USB Vault"));
    }

    #[test]
    fn finder_path_is_a_single_osascript_argument() {
        use std::ffi::OsStr;

        let path = "/Volumes/交换区\"; error \"injected";
        let command = finder_window_command(path);
        let args: Vec<_> = command.get_args().collect();
        assert_eq!(command.get_program(), OsStr::new("/usr/bin/osascript"));
        assert_eq!(args[0], OsStr::new("-e"));
        assert_eq!(args[1], OsStr::new(FINDER_WINDOW_SCRIPT));
        assert_eq!(args[2], OsStr::new("--"));
        assert_eq!(args[3], OsStr::new(path));
        assert!(!FINDER_WINDOW_SCRIPT.contains(path));
    }
}
