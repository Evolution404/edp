//! 协议帧类型与命令集。

use serde::{Deserialize, Serialize};

/// 请求帧。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

/// 响应帧。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub id: u64,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

/// RPC 错误。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RpcError {
    pub code: String,
    pub message: String,
}

impl RpcError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        RpcError {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

/// 事件帧（服务端主动推送）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub event: String,
    pub data: serde_json::Value,
}

/// 常用错误码。
pub mod codes {
    pub const PERMISSION_DENIED: &str = "PERMISSION_DENIED";
    pub const METHOD_NOT_FOUND: &str = "METHOD_NOT_FOUND";
    pub const BAD_PARAMS: &str = "BAD_PARAMS";
    pub const PASSWORD_MISMATCH: &str = "PASSWORD_MISMATCH";
    pub const NOT_FOUND: &str = "NOT_FOUND";
    pub const INTERNAL: &str = "INTERNAL";
    pub const ALREADY_EXISTS: &str = "ALREADY_EXISTS";
    pub const BUSY: &str = "BUSY";
}

/// 方法名常量。
pub mod method {
    pub const STATUS: &str = "status";
    pub const LIST_DISKS: &str = "list_disks";
    pub const PROBE: &str = "probe";
    pub const MOUNT: &str = "mount";
    pub const UNMOUNT: &str = "unmount";
    pub const SESSIONS: &str = "sessions";
    pub const KEYS_LS: &str = "keys.ls";
    pub const KEYS_ADD: &str = "keys.add";
    pub const KEYS_RM: &str = "keys.rm";
    pub const KEYS_UPDATE: &str = "keys.update";
    pub const CONFIG_GET: &str = "config.get";
    pub const CONFIG_SET: &str = "config.set";
    pub const DEVICES_LIST: &str = "devices.list";
    pub const DEVICES_POLICY_SET: &str = "devices.policy.set";
    pub const AUTO_MOUNT_GET: &str = "auto_mount.get";
    pub const AUTO_MOUNT_SET_MODE: &str = "auto_mount.set_mode";
    pub const LOGS_READ: &str = "logs.read";
    pub const SUBSCRIBE: &str = "subscribe";
    pub const UNSUBSCRIBE: &str = "unsubscribe";
    pub const DAEMON_SHUTDOWN: &str = "daemon.shutdown";
    pub const PERFORMANCE_SNAPSHOT: &str = "performance.snapshot";
    pub const PERFORMANCE_RESET: &str = "performance.reset";
    pub const PERFORMANCE_BENCHMARK_HIKSEMI: &str = "performance.benchmark_hiksemi";
}

/// 挂载/卸载操作的单阶段计时。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OperationTiming {
    pub operation_id: String,
    pub kind: String,
    pub stage: String,
    pub duration_ms: u64,
    pub outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 分层 I/O 基准报告。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BenchmarkReport {
    pub device_identity: String,
    pub layer: String,
    pub filesystem: Option<String>,
    pub mode: String,
    pub bytes: u64,
    pub block_size: u64,
    pub queue_depth: usize,
    #[serde(default = "default_access_pattern")]
    pub access_pattern: String,
    pub duration_ms: u64,
    pub throughput_bytes_s: u64,
    pub iops: f64,
    pub latency_p50_us: u64,
    pub latency_p95_us: u64,
    pub latency_p99_us: u64,
    pub cpu_seconds: f64,
    pub verified: bool,
}

fn default_access_pattern() -> String {
    "sequential".to_string()
}

/// 事件名常量。
pub mod event {
    pub const DISK_APPEARED: &str = "disk_appeared";
    pub const MOUNTED: &str = "mounted";
    pub const MOUNT_FAILED: &str = "mount_failed";
    pub const PASSWORD_NEEDED: &str = "password_needed";
    pub const UNMOUNTED: &str = "unmounted";
    pub const DISK_REMOVED: &str = "disk_removed";
    pub const DEVICE_DETECTED: &str = "device_detected";
    pub const DEVICE_NEEDS_SETUP: &str = "device_needs_setup";
    pub const DEVICE_POLICY_CHANGED: &str = "device_policy_changed";
    pub const AUTO_MOUNT_MODE_CHANGED: &str = "auto_mount_mode_changed";
}

/// 服务端状态摘要。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusInfo {
    pub version: String,
    pub uptime_s: u64,
    pub macfuse: Option<String>,
    pub keystore_ok: bool,
    pub auto_mount_enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_mount_mode: Option<AutoMountMode>,
}

/// 磁盘摘要（对外返回）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskSummary {
    pub bsd: String,
    pub rbsd: String,
    pub size: u64,
    pub media_name: String,
    pub is_edp: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

/// 密码库条目（对外返回：**绝不含明文密码**）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyEntry {
    pub id: String,
    pub label: String,
    pub device_id: String,
    pub partition_type: u32,
    pub password_crc: String,
    /// 首尾提示（如 `"00…aa"`），便于区分多条同盘密码。
    pub password_hint: String,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<String>,
}

/// 新增密码库条目参数（含明文密码，仅走 UDS 加密通道）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyAddParams {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disk: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    pub partition_type: u32,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AutoMountMode {
    Active,
    Paused,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevicePolicy {
    pub device_id: String,
    pub label: String,
    pub authorized: bool,
    pub partition_types: Vec<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_media_name: Option<String>,
}

/// mount 参数。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MountParams {
    pub disk: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partition_type: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub readonly: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
}
