//! daemon：launchd 常驻守护进程。
//!
//! 职责：磁盘事件监听 → EDP 盘识别 → keystore 密码匹配 → 自动挂载；
//! 通过 UDS JSON-RPC 服务 CLI / GUI。

mod config;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tracing::{info, warn};

use edp_core::discovery::{discover_volume, filesystem_magic};
use edp_core::volume::FileRawIo;
use edp_proto::{serve_with_broadcaster, EventBroadcaster, Handler};

use crate::keystore::Keystore;
use crate::session;

use config::{AutoMountMode, Config, DevicePolicy};

const DEFAULT_DATA_ROOT: &str = "/var/db/com.edp.usbvault";
const DEFAULT_CONFIG_PATH: &str = "/var/db/com.edp.usbvault/config.json";

#[derive(Debug, Clone)]
struct DetectedDisk {
    kind: &'static str,
    candidate_ids: Vec<String>,
}

/// daemon 全局状态（注入 RPC Context）。
pub struct DaemonState {
    pub keystore: Mutex<Keystore>,
    pub config: Mutex<Config>,
    pub config_path: PathBuf,
    pub broadcaster: EventBroadcaster,
    pub session_root: PathBuf,
    pub started_at: std::time::Instant,
    /// 当前已挂载会话的物理盘 bsd → session ids。一个盘可以同时挂载多个分区。
    pub mounted: Mutex<HashMap<String, HashSet<String>>>,
    /// 当前外置盘的只读识别结果。
    disk_inventory: Mutex<HashMap<String, DetectedDisk>>,
    /// 正在尝试自动挂载的盘（bsd），防并发重复尝试
    pub auto_mount_inflight: Mutex<std::collections::HashSet<String>>,
    /// 配置/授权变更后请求 watcher 立即重新评估当前已连接设备。
    pub rescan_requested: std::sync::atomic::AtomicBool,
    /// daemon.shutdown 置位；主线程据此退出
    pub shutdown: Arc<std::sync::atomic::AtomicBool>,
    /// 安全停止准备完成后阻止产生任何新的自动挂载。
    pub quiesced: std::sync::atomic::AtomicBool,
    /// 主线程句柄（shutdown 时 unpark）
    pub main_thread: std::thread::Thread,
    /// 最近的挂载/卸载阶段计时（最多 256 条）。
    pub performance_timings: Mutex<VecDeque<edp_proto::OperationTiming>>,
    /// 最近完成的分层基准；即使发起请求的诊断客户端断开也保留结果。
    pub benchmark_reports: Mutex<VecDeque<edp_proto::BenchmarkReport>>,
}

const DEFAULT_SESSION_ROOT: &str = "/var/db/com.edp.usbvault/sessions";

/// 默认授权用户白名单：
/// - root 守护进程：放行控制台登录用户（GUI/CLI 免 sudo 走 RPC）
/// - 非 root（测试/开发）：放行自身 euid
fn default_allowed_uids() -> Vec<u32> {
    let euid = unsafe { libc::geteuid() };
    if euid == 0 {
        // macOS：`stat -f %u /dev/console` 取当前控制台用户 uid
        if let Ok(out) = std::process::Command::new("stat")
            .args(["-f", "%u", "/dev/console"])
            .output()
        {
            if let Ok(s) = String::from_utf8(out.stdout) {
                if let Ok(uid) = s.trim().parse::<u32>() {
                    if uid != 0 {
                        return vec![uid];
                    }
                }
            }
        }
        Vec::new()
    } else {
        vec![euid]
    }
}

/// 启动 daemon（socket 可覆盖，测试用；launchd 调用 `daemon run`）。
pub fn run_with(
    socket_override: Option<&str>,
    config_path: Option<&Path>,
    session_root_override: Option<&Path>,
) -> Result<()> {
    let config_path = config_path.map(Path::to_path_buf).unwrap_or_else(|| {
        session_root_override
            .and_then(Path::parent)
            .map(|parent| parent.join("config.json"))
            .unwrap_or_else(|| PathBuf::from(DEFAULT_CONFIG_PATH))
    });
    let mut cfg = config::load(&config_path)?;
    // Persist schema migration immediately. Test-only socket overrides are applied
    // afterwards and therefore never leak into the stored configuration.
    config::save_atomic(&config_path, &cfg)?;
    if let Some(sock) = socket_override {
        cfg.socket_path = sock.to_string();
    }
    let session_root = session_root_override
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(DEFAULT_SESSION_ROOT));
    std::fs::create_dir_all(&session_root)?;
    // 回收上次非正常退出的孤儿挂载（daemon 重启后重新触发磁盘出现→自动挂载）
    session::cleanup_all_force(&session_root);

    let keystore_dir = session_root
        .parent()
        .unwrap_or(Path::new(DEFAULT_DATA_ROOT));
    let ks = Keystore::open(keystore_dir)?;
    let broadcaster = EventBroadcaster::new();

    let state = Arc::new(DaemonState {
        keystore: Mutex::new(ks),
        config: Mutex::new(cfg.clone()),
        config_path,
        broadcaster: broadcaster.clone(),
        session_root,
        started_at: std::time::Instant::now(),
        mounted: Mutex::new(HashMap::new()),
        disk_inventory: Mutex::new(HashMap::new()),
        auto_mount_inflight: Mutex::new(std::collections::HashSet::new()),
        rescan_requested: std::sync::atomic::AtomicBool::new(false),
        shutdown: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        quiesced: std::sync::atomic::AtomicBool::new(false),
        main_thread: std::thread::current(),
        performance_timings: Mutex::new(VecDeque::with_capacity(256)),
        benchmark_reports: Mutex::new(VecDeque::with_capacity(128)),
    });

    // The daemon executable lives inside the app bundle. If Finder removes the
    // app while the registered service is running, safely unmount, erase daemon
    // data, and exit instead of leaving a detached privileged process alive.
    if let Some(executable) = embedded_executable_path() {
        let orphan_state = state.clone();
        std::thread::spawn(move || {
            while !orphan_state
                .shutdown
                .load(std::sync::atomic::Ordering::SeqCst)
            {
                if !executable.exists() {
                    let _ = quiesce(&orphan_state, true, true, "app_removed");
                    break;
                }
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
        });
    }

    // diskutil activity 直接订阅 Disk Arbitration 事件；watcher 只在事件后
    // 做一次合并扫描，并保留 10s 低频容错扫描。
    {
        let state = state.clone();
        std::thread::spawn(move || disk_arbitration_event_loop(state));
    }
    {
        let state = state.clone();
        std::thread::spawn(move || {
            disk_watcher_loop(state);
        });
    }

    // RPC server（白名单为空时按运行身份派生默认授权用户）
    let allowed_uids = if cfg.allowed_uids.is_empty() {
        default_allowed_uids()
    } else {
        cfg.allowed_uids.clone()
    };
    let methods = build_methods()?;
    let handle = serve_with_broadcaster(
        &cfg.socket_path,
        methods,
        allowed_uids,
        state.clone() as Arc<dyn std::any::Any + Send + Sync>,
        broadcaster,
    )
    .with_context(|| format!("监听 {} 失败", cfg.socket_path))?;

    info!(
        "usbcore daemon 就绪: socket={} keystore_ok=true auto_mount_mode={:?}",
        cfg.socket_path, cfg.auto_mount_mode
    );

    // 主线程常驻（launchd 管理生命周期；daemon.shutdown 或 SIGTERM 退出）
    let mut handle = handle;
    while !state.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
        std::thread::park();
    }
    info!("usbcore daemon 收到 shutdown，退出");
    handle.shutdown();
    Ok(())
}

fn embedded_executable_path() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    executable
        .to_string_lossy()
        .contains(".app/Contents/")
        .then_some(executable)
}

fn build_methods() -> Result<HashMap<String, Handler>> {
    use edp_proto::method as m;
    let mut map: HashMap<String, Handler> = HashMap::new();
    map.insert(m::STATUS.to_string(), Arc::new(handle_status));
    map.insert(m::LIST_DISKS.to_string(), Arc::new(handle_list_disks));
    map.insert(m::PROBE.to_string(), Arc::new(handle_probe));
    map.insert(m::MOUNT.to_string(), Arc::new(handle_mount));
    map.insert(m::UNMOUNT.to_string(), Arc::new(handle_unmount));
    map.insert(m::SESSIONS.to_string(), Arc::new(handle_sessions));
    map.insert(m::KEYS_LS.to_string(), Arc::new(handle_keys_ls));
    map.insert(m::KEYS_ADD.to_string(), Arc::new(handle_keys_add));
    map.insert(m::KEYS_RM.to_string(), Arc::new(handle_keys_rm));
    map.insert(m::KEYS_UPDATE.to_string(), Arc::new(handle_keys_update));
    map.insert(m::CONFIG_GET.to_string(), Arc::new(handle_config_get));
    map.insert(m::CONFIG_SET.to_string(), Arc::new(handle_config_set));
    map.insert(m::DEVICES_LIST.to_string(), Arc::new(handle_devices_list));
    map.insert(
        m::DEVICES_POLICY_SET.to_string(),
        Arc::new(handle_devices_policy_set),
    );
    map.insert(
        m::AUTO_MOUNT_GET.to_string(),
        Arc::new(handle_auto_mount_get),
    );
    map.insert(
        m::AUTO_MOUNT_SET_MODE.to_string(),
        Arc::new(handle_auto_mount_set_mode),
    );
    map.insert(m::LOGS_READ.to_string(), Arc::new(handle_logs_read));
    map.insert(m::DAEMON_SHUTDOWN.to_string(), Arc::new(handle_shutdown));
    map.insert(
        m::PERFORMANCE_SNAPSHOT.to_string(),
        Arc::new(handle_performance_snapshot),
    );
    map.insert(
        m::PERFORMANCE_RESET.to_string(),
        Arc::new(handle_performance_reset),
    );
    map.insert(
        m::PERFORMANCE_BENCHMARK_HIKSEMI.to_string(),
        Arc::new(handle_performance_benchmark_hiksemi),
    );
    map.insert(
        m::SUBSCRIBE.to_string(),
        Arc::new(|_c, _p| Ok(json!({"ok": true}))),
    );
    map.insert(
        m::UNSUBSCRIBE.to_string(),
        Arc::new(|_c, _p| Ok(json!({"ok": true}))),
    );
    Ok(map)
}

// ---------- RPC handlers ----------

fn daemon(ctx: &edp_proto::Context) -> Result<&DaemonState, edp_proto::RpcError> {
    ctx.state::<DaemonState>()
        .ok_or_else(|| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, "daemon 状态缺失"))
}

fn handle_status(ctx: &edp_proto::Context, _p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let ks = d.keystore.lock().unwrap();
    let cfg = d.config.lock().unwrap();
    let mounted_sessions: usize = d.mounted.lock().unwrap().values().map(HashSet::len).sum();
    Ok(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "uptime_s": d.started_at.elapsed().as_secs(),
        "macfuse": edp_macos::macfuse_version(),
        "keystore_ok": true,
        "keystore_entries": ks.all().len(),
        "auto_mount_mode": cfg.auto_mount_mode,
        // v1 compatibility for older CLI/GUI clients.
        "auto_mount_enabled": cfg.auto_mount_mode == AutoMountMode::Active,
        "mounted_sessions": mounted_sessions,
        // macOS 15 起 launchd 守护进程默认无权访问可移动磁盘（TCC），
        // 需在系统设置授予“完整磁盘访问权限”。为 false 时自动挂载不可用。
        "disk_access_ok": std::fs::File::open("/dev/rdisk0").is_ok(),
    }))
}

fn handle_list_disks(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let all = p.get("all").and_then(|x| x.as_bool()).unwrap_or(false);
    // 直接透传 all：此前 `!all` 反转导致 GUI 请求"外置盘"时反而枚举全部盘
    // （含 hdiutil FUSE 镜像盘），逐盘 diskutil info 对镜像盘挂起 → list_disks
    // RPC 卡 ~10s（密码库页卡顿根因）。
    let disks = edp_macos::list_disks(all).map_err(rpc_io)?;
    let mounted = d.mounted.lock().unwrap();
    let inventory = d.disk_inventory.lock().unwrap();
    let out: Vec<Value> = disks
        .into_iter()
        .map(|dk| {
            json!({
                "bsd": dk.bsd,
                "rbsd": dk.rbsd,
                "size": dk.total_size,
                "media_name": dk.media_name,
                "is_edp": inventory.get(&dk.bsd).map(|d| d.kind == "edp").unwrap_or(false),
                "session_id": mounted.get(&dk.bsd).and_then(|s| s.iter().next()),
                "session_ids": mounted.get(&dk.bsd).map(|s| s.iter().cloned().collect::<Vec<_>>()).unwrap_or_default(),
            })
        })
        .collect();
    Ok(json!(out))
}

fn handle_probe(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let _d = daemon(ctx)?;
    let disk = p.get("disk").and_then(|x| x.as_str()).unwrap_or_default();
    if !disk.starts_with("/dev/rdisk") {
        return Err(edp_proto::RpcError::new(
            edp_proto::codes::BAD_PARAMS,
            "disk 须为 /dev/rdiskN",
        ));
    }
    let password = p
        .get("password")
        .and_then(|x| x.as_str())
        .unwrap_or_default();
    let ptype = p
        .get("partition_type")
        .and_then(|x| x.as_u64())
        .map(|v| v as u32)
        .unwrap_or(4);
    probe_impl(Path::new(disk), password, ptype)
        .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))
}

fn probe_impl(source: &Path, password: &str, ptype: u32) -> Result<Value> {
    let (desc, hit_id, magic) = discover_verified(source, None, password, ptype)?;
    Ok(json!({
        "ok": true,
        "device_id": hit_id,
        "partition": desc.public_dict(),
        "filesystem_magic": magic,
    }))
}

fn discover_verified(
    source: &Path,
    explicit_device_id: Option<&str>,
    password: &str,
    ptype: u32,
) -> Result<(edp_core::lba12::VolumeDescriptor, String, &'static str)> {
    let io = std::sync::Arc::new(FileRawIo::open(source, true)?);
    let mut hints = crate::build_hints_for(source);
    hints.explicit = explicit_device_id.map(str::to_string);
    let (desc, hit_id) = discover_volume(io.as_ref(), &hints, password, ptype)?;
    let vol = edp_core::volume::EncryptedPartitionIO::open(io, desc.clone(), true)?;
    let mut boot = [0u8; 512];
    vol.read(0, &mut boot)?;
    let magic = filesystem_magic(&boot).context("解密分区没有可识别的文件系统签名")?;
    Ok((desc, hit_id, magic))
}

fn register_session(d: &DaemonState, bsd: &str, sid: &str) {
    d.mounted
        .lock()
        .unwrap()
        .entry(bsd.to_string())
        .or_default()
        .insert(sid.to_string());
}

fn unregister_session(d: &DaemonState, sid: &str) -> Option<(String, bool)> {
    let mut mounted = d.mounted.lock().unwrap();
    let bsd = mounted
        .iter()
        .find(|(_, sessions)| sessions.contains(sid))
        .map(|(bsd, _)| bsd.clone())?;
    let sessions = mounted.get_mut(&bsd)?;
    sessions.remove(sid);
    let last = sessions.is_empty();
    if last {
        mounted.remove(&bsd);
    }
    Some((bsd, last))
}

fn record_timing(d: &DaemonState, timing: edp_proto::OperationTiming) {
    let mut timings = d.performance_timings.lock().unwrap();
    if timings.len() == 256 {
        timings.pop_front();
    }
    timings.push_back(timing);
}

#[allow(clippy::too_many_arguments)]
fn timing(
    operation_id: &str,
    kind: &str,
    stage: &str,
    started: std::time::Instant,
    outcome: &str,
    device_id: Option<&str>,
    session_id: Option<&str>,
    error: Option<String>,
) -> edp_proto::OperationTiming {
    edp_proto::OperationTiming {
        operation_id: operation_id.to_string(),
        kind: kind.to_string(),
        stage: stage.to_string(),
        duration_ms: started.elapsed().as_millis() as u64,
        outcome: outcome.to_string(),
        device_id: device_id.map(str::to_string),
        session_id: session_id.map(str::to_string),
        error,
    }
}

fn handle_mount(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let operation_id = uuid::Uuid::new_v4().to_string();
    let operation_started = std::time::Instant::now();
    let disk = p.get("disk").and_then(|x| x.as_str()).unwrap_or_default();
    let ptype = p
        .get("partition_type")
        .and_then(|x| x.as_u64())
        .map(|v| v as u32)
        .unwrap_or(4);
    let readonly = p.get("readonly").and_then(|x| x.as_bool()).unwrap_or(false);
    let password = p
        .get("password")
        .and_then(|x| x.as_str())
        .unwrap_or_default();
    let source = PathBuf::from(disk);
    let io = std::sync::Arc::new(FileRawIo::open(&source, true).map_err(rpc_io)?);
    let hints = crate::build_hints_for(&source);

    // 密码：显式优先；空则从密码库匹配 (device_id, ptype) 逐条尝试
    // 三元组第三位为命中的密码库条目 id（无则空串）
    let (desc, hit_id, touched_id): (_, String, String) = if password.is_empty() {
        let device_id = p
            .get("device_id")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                edp_core::discovery::candidate_device_ids(io.as_ref(), &hints)
                    .into_iter()
                    .next()
            });
        let Some(device_id) = device_id else {
            return Err(edp_proto::RpcError::new(
                edp_proto::codes::BAD_PARAMS,
                "无法解析 device_id：请提供密码或 device_id",
            ));
        };
        let candidates = d.keystore.lock().unwrap().candidates(&device_id, ptype);
        let mut found: Option<(_, String, String)> = None;
        for rec in candidates {
            match discover_verified(&source, Some(&device_id), &rec.password, ptype) {
                Ok((desc, id, _)) => {
                    found = Some((desc, id, rec.id.clone()));
                    break;
                }
                Err(_) => continue,
            }
        }
        found.ok_or_else(|| {
            edp_proto::RpcError::new(
                edp_proto::codes::PASSWORD_MISMATCH,
                "密码库无匹配条目或密码均不匹配",
            )
        })?
    } else {
        let (desc, id, _) = discover_verified(&source, None, password, ptype)
            .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
        (desc, id, String::new())
    };

    let session_root = d.session_root.clone();
    let bsd = disk
        .trim_start_matches("/dev/")
        .trim_start_matches('r')
        .to_string();
    let physical_already_prepared = d
        .mounted
        .lock()
        .unwrap()
        .get(&bsd)
        .is_some_and(|sessions| !sessions.is_empty());
    if source.starts_with("/dev/") && !physical_already_prepared {
        let started = std::time::Instant::now();
        let result = edp_macos::unmount_disk(&bsd);
        record_timing(
            d,
            timing(
                &operation_id,
                "mount",
                "physical_unmount",
                started,
                if result.is_ok() { "ok" } else { "error" },
                Some(&hit_id),
                None,
                result.as_ref().err().map(ToString::to_string),
            ),
        );
        result.map_err(rpc_io)?;
    }
    let attach_started = std::time::Instant::now();
    let state = match session::mount_and_attach(
        &source,
        &desc,
        &hit_id,
        readonly,
        None,
        None,
        &session_root,
    ) {
        Ok(state) => state,
        Err(error) => {
            record_timing(
                d,
                timing(
                    &operation_id,
                    "mount",
                    "bridge_attach",
                    attach_started,
                    "error",
                    Some(&hit_id),
                    None,
                    Some(error.to_string()),
                ),
            );
            if source.starts_with("/dev/") && !physical_already_prepared {
                let _ = edp_macos::mount_disk(&bsd);
            }
            return Err(edp_proto::RpcError::new(
                edp_proto::codes::INTERNAL,
                error.to_string(),
            ));
        }
    };
    let sid = state["session_id"].as_str();
    record_timing(
        d,
        timing(
            &operation_id,
            "mount",
            "bridge_attach",
            attach_started,
            "ok",
            Some(&hit_id),
            sid,
            None,
        ),
    );
    record_timing(
        d,
        timing(
            &operation_id,
            "mount",
            "total",
            operation_started,
            "ok",
            Some(&hit_id),
            sid,
            None,
        ),
    );
    if let Some(sid) = state["session_id"].as_str() {
        register_session(d, &bsd, sid);
        d.broadcaster
            .broadcast(edp_proto::event::MOUNTED, state.clone());
        // 命中密码库条目 → 标记最近使用
        if !touched_id.is_empty() {
            if let Ok(mut ks) = d.keystore.try_lock() {
                ks.touch(&touched_id);
            }
        }
    }
    Ok(state)
}

fn handle_unmount(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let operation_id = uuid::Uuid::new_v4().to_string();
    let operation_started = std::time::Instant::now();
    let sid = p
        .get("session_id")
        .and_then(|x| x.as_str())
        .unwrap_or_default();
    let force = p.get("force").and_then(|x| x.as_bool()).unwrap_or(false);
    let session_root = d.session_root.clone();
    let result = session::unmount(sid, force, &session_root);
    record_timing(
        d,
        timing(
            &operation_id,
            "unmount",
            "detach_and_sync",
            operation_started,
            if result.is_ok() { "ok" } else { "error" },
            None,
            Some(sid),
            result.as_ref().err().map(ToString::to_string),
        ),
    );
    result.map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
    let restore_started = std::time::Instant::now();
    if let Some((bsd, true)) = unregister_session(d, sid).filter(|(bsd, _)| bsd.starts_with("disk"))
    {
        let _ = edp_macos::mount_disk(&bsd);
    }
    record_timing(
        d,
        timing(
            &operation_id,
            "unmount",
            "restore_public_disk",
            restore_started,
            "ok",
            None,
            Some(sid),
            None,
        ),
    );
    d.broadcaster
        .broadcast(edp_proto::event::UNMOUNTED, json!({ "session_id": sid }));
    Ok(json!({ "unmounted": sid }))
}

fn handle_sessions(ctx: &edp_proto::Context, _p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let session_root = d.session_root.clone();
    session::list_active(&session_root)
        .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))
}

fn handle_keys_ls(ctx: &edp_proto::Context, _p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let ks = d.keystore.lock().unwrap();
    let out: Vec<Value> = ks
        .all()
        .iter()
        .map(|r| {
            json!({
                "id": r.id,
                "label": r.label,
                "device_id": r.device_id,
                "partition_type": r.partition_type,
                "password_crc": format!("{:08x}", edp_core::crc32::crc32_bare(r.password.as_bytes())),
                "password_hint": password_hint(&r.password),
                "created_at": r.created_at,
                "last_used_at": r.last_used_at,
            })
        })
        .collect();
    Ok(json!(out))
}

fn password_hint(pwd: &str) -> String {
    let b = pwd.as_bytes();
    let n = b.len();
    if n <= 4 {
        "***".to_string()
    } else {
        format!(
            "{}…{}",
            String::from_utf8_lossy(&b[..2]),
            String::from_utf8_lossy(&b[n - 2..])
        )
    }
}

fn handle_keys_add(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let label = p
        .get("label")
        .and_then(|x| x.as_str())
        .unwrap_or("EDP 盘")
        .to_string();
    let partition_type = p
        .get("partition_type")
        .and_then(|x| x.as_u64())
        .map(|v| v as u32)
        .unwrap_or(4);
    let password = p
        .get("password")
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string();
    if password.is_empty() {
        return Err(edp_proto::RpcError::new(
            edp_proto::codes::BAD_PARAMS,
            "password 不能为空",
        ));
    }
    // device_id 解析：优先显式，否则从 disk probe
    let device_id = if let Some(dev) = p.get("device_id").and_then(|x| x.as_str()) {
        Some(dev.to_string())
    } else if let Some(disk) = p.get("disk").and_then(|x| x.as_str()) {
        // 用 keystore 里已有的同盘 device_id，或 probe
        let source = PathBuf::from(disk);
        let (_, hit, _) = discover_verified(&source, None, &password, partition_type)
            .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
        Some(hit)
    } else {
        None
    };
    let Some(device_id) = device_id else {
        return Err(edp_proto::RpcError::new(
            edp_proto::codes::BAD_PARAMS,
            "无法解析 device_id：请指定 device_id 或 disk",
        ));
    };
    let mut ks = d.keystore.lock().unwrap();
    let id = ks
        .add(crate::keystore::KeyRecord {
            id: String::new(),
            label,
            device_id,
            partition_type,
            password,
            created_at: String::new(),
            last_used_at: None,
        })
        .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
    Ok(json!({ "id": id }))
}

fn handle_keys_rm(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let id = p.get("id").and_then(|x| x.as_str()).unwrap_or_default();
    let mut ks = d.keystore.lock().unwrap();
    let removed = ks
        .remove(id)
        .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
    Ok(json!({ "removed": removed }))
}

fn handle_keys_update(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let id = p.get("id").and_then(|x| x.as_str()).unwrap_or_default();
    let mut ks = d.keystore.lock().unwrap();
    let ok = ks
        .update(id, p.clone())
        .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
    Ok(json!({ "updated": ok }))
}

fn handle_config_get(ctx: &edp_proto::Context, _p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let cfg = d.config.lock().unwrap();
    let mut value = serde_json::to_value(&*cfg).unwrap();
    value["auto_mount_enabled"] = json!(cfg.auto_mount_mode == AutoMountMode::Active);
    Ok(value)
}

fn replace_config(d: &DaemonState, mut next: Config) -> Result<Value, edp_proto::RpcError> {
    next.validate().map_err(rpc_internal)?;
    config::save_atomic(&d.config_path, &next).map_err(rpc_internal)?;
    let mut value = serde_json::to_value(&next).map_err(rpc_internal)?;
    value["auto_mount_enabled"] = json!(next.auto_mount_mode == AutoMountMode::Active);
    *d.config.lock().unwrap() = next;
    Ok(value)
}

fn handle_config_set(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    // 敏感字段（授权白名单/socket 路径）仅 root 可改；旧版自动挂载布尔值继续兼容，
    // 新 GUI 使用 auto_mount.set_mode。
    // 注意：到这里调用者已通过 allowed_uids 白名单鉴权，此处只做字段级权限分级。
    let touches_sensitive = p.get("allowed_uids").is_some() || p.get("socket_path").is_some();
    if touches_sensitive && !ctx.is_root() {
        return Err(edp_proto::RpcError::new(
            edp_proto::codes::PERMISSION_DENIED,
            "仅 root 可修改授权白名单 / socket 路径",
        ));
    }
    let mut cfg = d.config.lock().unwrap().clone();
    let mut resume = false;
    if let Some(b) = p.get("auto_mount_enabled").and_then(|x| x.as_bool()) {
        cfg.auto_mount_mode = if b {
            resume = true;
            AutoMountMode::Active
        } else {
            AutoMountMode::Paused
        };
    }
    if ctx.is_root() {
        if let Some(v) = p.get("allowed_uids").and_then(|x| x.as_array()) {
            cfg.allowed_uids = v
                .iter()
                .filter_map(|x| x.as_u64())
                .map(|x| x as u32)
                .collect();
        }
        if let Some(s) = p.get("socket_path").and_then(|x| x.as_str()) {
            cfg.socket_path = s.to_string();
        }
    }
    let value = replace_config(d, cfg)?;
    if resume {
        d.rescan_requested
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
    Ok(value)
}

fn handle_auto_mount_get(
    ctx: &edp_proto::Context,
    _p: Value,
) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let cfg = d.config.lock().unwrap();
    Ok(json!({ "mode": cfg.auto_mount_mode }))
}

fn handle_auto_mount_set_mode(
    ctx: &edp_proto::Context,
    p: Value,
) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let mode: AutoMountMode = serde_json::from_value(
        p.get("mode")
            .cloned()
            .ok_or_else(|| edp_proto::RpcError::new(edp_proto::codes::BAD_PARAMS, "缺少 mode"))?,
    )
    .map_err(|_| {
        edp_proto::RpcError::new(edp_proto::codes::BAD_PARAMS, "mode 仅允许 active 或 paused")
    })?;
    let mut next = d.config.lock().unwrap().clone();
    next.auto_mount_mode = mode;
    replace_config(d, next)?;
    d.broadcaster.broadcast(
        edp_proto::event::AUTO_MOUNT_MODE_CHANGED,
        json!({ "mode": mode }),
    );
    if mode == AutoMountMode::Active {
        d.rescan_requested
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
    Ok(json!({ "mode": mode }))
}

fn handle_devices_policy_set(
    ctx: &edp_proto::Context,
    p: Value,
) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let policy: DevicePolicy = serde_json::from_value(p).map_err(|error| {
        edp_proto::RpcError::new(
            edp_proto::codes::BAD_PARAMS,
            format!("设备策略格式错误: {error}"),
        )
    })?;
    let should_evaluate = !policy.partition_types.is_empty();
    let device_id = policy.device_id.clone();
    let mut next = d.config.lock().unwrap().clone();
    next.set_policy(policy).map_err(rpc_internal)?;
    let value = replace_config(d, next)?;
    d.broadcaster.broadcast(
        edp_proto::event::DEVICE_POLICY_CHANGED,
        json!({ "device_id": device_id }),
    );
    if should_evaluate {
        d.rescan_requested
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
    Ok(value)
}

fn handle_devices_list(ctx: &edp_proto::Context, _p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let disks = edp_macos::list_disks(false).map_err(rpc_io)?;
    for disk in &disks {
        if !d.disk_inventory.lock().unwrap().contains_key(&disk.bsd) {
            if let Ok(detected) = inspect_disk(&disk.bsd, &disk.media_name, disk.total_size) {
                d.disk_inventory
                    .lock()
                    .unwrap()
                    .insert(disk.bsd.clone(), detected);
            }
        }
    }

    let cfg = d.config.lock().unwrap().clone();
    let keys = d.keystore.lock().unwrap().all().to_vec();
    let inventory = d.disk_inventory.lock().unwrap().clone();
    let mounted = d.mounted.lock().unwrap().clone();
    let active_sessions = session::list_active(&d.session_root)
        .ok()
        .and_then(|value| value.get("sessions").and_then(Value::as_array).cloned())
        .unwrap_or_default();
    let mut out = Vec::new();
    let mut connected_ids = HashSet::new();

    for disk in disks {
        let detected = inventory.get(&disk.bsd);
        let candidates = detected
            .map(|detected| detected.candidate_ids.clone())
            .unwrap_or_default();
        let device_id = candidates
            .iter()
            .find(|candidate| {
                cfg.device_policies
                    .iter()
                    .any(|policy| policy.device_id.as_str() == candidate.as_str())
                    || keys
                        .iter()
                        .any(|key| key.device_id.as_str() == candidate.as_str())
            })
            .cloned()
            .or_else(|| candidates.first().cloned());
        if let Some(id) = &device_id {
            connected_ids.insert(id.clone());
        }
        let policy = device_id.as_ref().and_then(|id| {
            cfg.device_policies
                .iter()
                .find(|policy| policy.device_id == *id)
        });
        let credential_types: Vec<u32> = device_id
            .as_ref()
            .map(|id| {
                let mut types: Vec<u32> = keys
                    .iter()
                    .filter(|key| key.device_id == *id)
                    .map(|key| key.partition_type)
                    .collect();
                types.sort_unstable();
                types.dedup();
                types
            })
            .unwrap_or_default();
        let mounted_partition_types: Vec<u32> = active_sessions
            .iter()
            .filter(|item| item.get("source").and_then(Value::as_str) == Some(disk.rbsd.as_str()))
            .filter_map(|item| {
                item.get("partition")
                    .and_then(|partition| partition.get("partition_type"))
                    .and_then(Value::as_u64)
                    .map(|value| value as u32)
            })
            .collect();
        out.push(json!({
            "bsd": disk.bsd,
            "rbsd": disk.rbsd,
            "media_name": disk.media_name,
            "size": disk.total_size,
            "connected": true,
            "kind": detected.map(|detected| detected.kind).unwrap_or("unknown"),
            "device_id": device_id,
            "policy": policy,
            "credential_partition_types": credential_types,
            "session_ids": mounted.get(&disk.bsd).map(|ids| ids.iter().cloned().collect::<Vec<_>>()).unwrap_or_default(),
            "mounted_partition_types": mounted_partition_types,
        }));
    }
    for policy in &cfg.device_policies {
        if connected_ids.contains(&policy.device_id) {
            continue;
        }
        let mut credential_types: Vec<u32> = keys
            .iter()
            .filter(|key| key.device_id == policy.device_id)
            .map(|key| key.partition_type)
            .collect();
        credential_types.sort_unstable();
        credential_types.dedup();
        out.push(json!({
            "bsd": Value::Null,
            "rbsd": Value::Null,
            "media_name": policy.last_media_name.clone().unwrap_or_else(|| policy.label.clone()),
            "size": 0,
            "connected": false,
            "kind": "edp",
            "device_id": policy.device_id,
            "policy": policy,
            "credential_partition_types": credential_types,
            "session_ids": [],
            "mounted_partition_types": [],
        }));
    }
    Ok(json!({ "devices": out, "auto_mount_mode": cfg.auto_mount_mode }))
}

/// 读 daemon 日志尾部（若构建配置启用了文件日志）。
fn handle_logs_read(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let lines = p.get("lines").and_then(|x| x.as_u64()).unwrap_or(100) as usize;
    let mut logs = Vec::new();
    for name in ["daemon.err", "daemon.out"] {
        let path = Path::new(DEFAULT_DATA_ROOT).join("logs").join(name);
        if let Some(tail) = tail_file(&path, lines) {
            logs.push(json!({ "file": name, "lines": tail }));
        }
    }
    let _ = ctx;
    Ok(json!({ "logs": logs }))
}

fn handle_performance_snapshot(
    ctx: &edp_proto::Context,
    _p: Value,
) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let mut snapshot = session::performance_snapshot(&d.session_root);
    snapshot["operation_timings"] =
        serde_json::to_value(d.performance_timings.lock().unwrap().clone())
            .map_err(rpc_internal)?;
    snapshot["benchmark_reports"] =
        serde_json::to_value(d.benchmark_reports.lock().unwrap().clone()).map_err(rpc_internal)?;
    Ok(snapshot)
}

fn handle_performance_reset(
    ctx: &edp_proto::Context,
    _p: Value,
) -> Result<Value, edp_proto::RpcError> {
    if !ctx.is_root() {
        return Err(edp_proto::RpcError::new(
            edp_proto::codes::PERMISSION_DENIED,
            "performance.reset 仅允许 root 调用",
        ));
    }
    let d = daemon(ctx)?;
    session::reset_performance(&d.session_root).map_err(rpc_internal)?;
    d.performance_timings.lock().unwrap().clear();
    d.benchmark_reports.lock().unwrap().clear();
    Ok(json!({ "ok": true }))
}

fn handle_performance_benchmark_hiksemi(
    ctx: &edp_proto::Context,
    p: Value,
) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let mode = crate::perf::mode_from_name(p.get("mode").and_then(Value::as_str).unwrap_or("read"))
        .map_err(rpc_internal)?;
    let gib = p.get("gib").and_then(Value::as_u64).unwrap_or(32);
    let block_kib = p.get("block_kib").and_then(Value::as_u64).unwrap_or(1024);
    let queue_depth = p.get("queue_depth").and_then(Value::as_u64).unwrap_or(1) as usize;
    let destructive = p
        .get("destructive")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let reports = crate::perf::hiksemi_raw_reports(
        mode,
        gib,
        block_kib,
        queue_depth,
        destructive,
        "7A6726BC6646D8C2",
        "0x2bdf",
        "0x0300",
    )
    .map_err(rpc_internal)?;
    {
        let mut recent = d.benchmark_reports.lock().unwrap();
        for report in &reports {
            if recent.len() == 128 {
                recent.pop_front();
            }
            recent.push_back(report.clone());
        }
    }
    persist_benchmark_reports(&reports).map_err(rpc_internal)?;
    Ok(json!({ "reports": reports }))
}

fn persist_benchmark_reports(reports: &[edp_proto::BenchmarkReport]) -> anyhow::Result<()> {
    let directory = Path::new(DEFAULT_DATA_ROOT).join("performance");
    std::fs::create_dir_all(&directory)?;
    let target = directory.join("benchmark-latest.json");
    let temporary = directory.join(format!(".benchmark-{}.tmp", std::process::id()));
    std::fs::write(&temporary, serde_json::to_vec_pretty(reports)?)?;
    std::fs::rename(temporary, target)?;
    Ok(())
}

fn tail_file(path: &Path, n: usize) -> Option<Vec<String>> {
    let data = std::fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&data);
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(n);
    Some(lines[start..].iter().map(|s| s.to_string()).collect())
}

/// 安全卸载全部会话，并按需要清除数据或退出。
fn handle_shutdown(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let exit = p.get("exit").and_then(Value::as_bool).unwrap_or(true);
    let purge_data = p
        .get("purge_data")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    quiesce(d, purge_data, exit, "daemon_stop").map_err(rpc_internal)?;
    Ok(json!({ "ok": true, "exit": exit, "purged": purge_data }))
}

fn quiesce(d: &DaemonState, purge_data: bool, exit: bool, reason: &str) -> Result<()> {
    d.quiesced.store(true, std::sync::atomic::Ordering::SeqCst);
    let active = match session::list_active(&d.session_root) {
        Ok(active) => active,
        Err(error) => {
            d.quiesced.store(false, std::sync::atomic::Ordering::SeqCst);
            return Err(error);
        }
    };
    let sessions = active["sessions"].as_array().cloned().unwrap_or_default();
    let mut physical_disks = HashSet::new();
    for item in &sessions {
        let sid = item["session_id"].as_str().unwrap_or_default();
        if sid.is_empty() {
            continue;
        }
        if let Err(error) = session::unmount(sid, false, &d.session_root) {
            d.quiesced.store(false, std::sync::atomic::Ordering::SeqCst);
            bail!("安全卸载会话 {sid} 失败，daemon 保持运行: {error}");
        }
        let _ = unregister_session(d, sid);
        if let Some(source) = item["source"]
            .as_str()
            .filter(|source| source.starts_with("/dev/"))
        {
            if let Some(name) = Path::new(source).file_name().and_then(|name| name.to_str()) {
                physical_disks.insert(name.trim_start_matches('r').to_string());
            }
        }
        d.broadcaster.broadcast(
            edp_proto::event::UNMOUNTED,
            json!({ "session_id": sid, "reason": reason }),
        );
    }
    d.mounted.lock().unwrap().clear();
    for bsd in physical_disks {
        let _ = edp_macos::mount_disk(&bsd);
    }
    if purge_data {
        let data_root = d
            .session_root
            .parent()
            .unwrap_or_else(|| Path::new(DEFAULT_DATA_ROOT));
        if data_root == Path::new(DEFAULT_DATA_ROOT) {
            let _ = std::fs::remove_dir_all(data_root);
        }
    }
    if exit {
        d.shutdown.store(true, std::sync::atomic::Ordering::SeqCst);
        d.main_thread.unpark();
    }
    Ok(())
}

fn rpc_io(e: std::io::Error) -> edp_proto::RpcError {
    edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string())
}

fn rpc_internal(error: impl std::fmt::Display) -> edp_proto::RpcError {
    edp_proto::RpcError::new(edp_proto::codes::INTERNAL, error.to_string())
}

// ---------- Service Management 状态 ----------

/// daemon 在线状态。注册、启停和注销由 App 内的 SMAppService 控制。
pub fn status(socket: &str) -> Result<()> {
    let live = match edp_proto::Client::connect(socket) {
        Ok(mut client) => client.call(edp_proto::method::STATUS, json!({})).ok(),
        Err(_) => None,
    };
    let embedded = std::env::current_exe()
        .ok()
        .is_some_and(|path| path.to_string_lossy().contains(".app/Contents/"));
    let mut report = json!({
        "embedded": embedded,
        "running": live.is_some(),
        "online": live.is_some(),
        "socket": socket,
        "macfuse": edp_macos::macfuse_version(),
    });
    if let Some(status) = live {
        report["status"] = status;
    }
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}

// ---------- 磁盘监听与安全自动挂载 ----------

const AUTO_MOUNT_MAX_RETRIES: u32 = 12;
const AUTO_MOUNT_RETRY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EvaluationOutcome {
    Done,
    Retry,
}

fn inspect_disk(bsd: &str, _media_name: &str, size: u64) -> std::io::Result<DetectedDisk> {
    use std::os::unix::fs::FileExt;

    let source = PathBuf::from(format!("/dev/r{bsd}"));
    let file = std::fs::File::open(&source)?;
    let mut lba7 = [0u8; 512];
    file.read_exact_at(&mut lba7, 7 * 512)?;

    let structurally_edp = lba7_is_structurally_edp(&lba7, size);
    if !structurally_edp {
        return Ok(DetectedDisk {
            kind: "ordinary",
            candidate_ids: Vec::new(),
        });
    }

    let io = FileRawIo::open(&source, true)?;
    let hints = crate::build_hints_for(&source);
    let candidate_ids = edp_core::discovery::candidate_device_ids(&io, &hints);
    Ok(DetectedDisk {
        kind: "edp",
        candidate_ids,
    })
}

fn lba7_is_structurally_edp(lba7: &[u8; 512], size: u64) -> bool {
    edp_core::lba7::recover_lba7(lba7)
        .ok()
        .map(|(_, plain)| {
            (0..8).any(|index| {
                let entry = &plain[index * 0x40..(index + 1) * 0x40];
                if &entry[..4] != b"EDPF" {
                    return false;
                }
                let start = u64::from_le_bytes(entry[0x18..0x20].try_into().unwrap());
                let bytes = u64::from_le_bytes(entry[0x28..0x30].try_into().unwrap());
                start > 0
                    && bytes > 0
                    && (size == 0 || start.saturating_mul(512).saturating_add(bytes) <= size)
            })
        })
        .unwrap_or(false)
}

fn spawn_auto_mount(state: &Arc<DaemonState>, bsd: &str) {
    if state.quiesced.load(std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    {
        let mut inflight = state.auto_mount_inflight.lock().unwrap();
        if !inflight.insert(bsd.to_string()) {
            return;
        }
    }
    let state = state.clone();
    let bsd = bsd.to_string();
    std::thread::spawn(move || {
        for _ in 0..AUTO_MOUNT_MAX_RETRIES {
            if maybe_auto_mount(&state, &bsd) == EvaluationOutcome::Done {
                break;
            }
            std::thread::sleep(AUTO_MOUNT_RETRY_INTERVAL);
        }
        state.auto_mount_inflight.lock().unwrap().remove(&bsd);
    });
}

fn disk_watcher_loop(state: Arc<DaemonState>) {
    let mut prev: HashSet<String> = HashSet::new();
    let mut last_fallback = std::time::Instant::now() - std::time::Duration::from_secs(10);
    while !state.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
        let requested = state
            .rescan_requested
            .swap(false, std::sync::atomic::Ordering::SeqCst);
        if !requested && last_fallback.elapsed() < std::time::Duration::from_secs(10) {
            std::thread::sleep(std::time::Duration::from_millis(100));
            continue;
        }
        // 合并 Disk Arbitration 的同一批多条消息。
        std::thread::sleep(std::time::Duration::from_millis(150));
        let disks = edp_macos::list_disks(false).unwrap_or_default();
        last_fallback = std::time::Instant::now();
        let cur: HashSet<String> = disks.iter().map(|disk| disk.bsd.clone()).collect();
        for disk in &disks {
            if !prev.contains(&disk.bsd) {
                info!("磁盘出现: {}", disk.bsd);
                state
                    .broadcaster
                    .broadcast(edp_proto::event::DISK_APPEARED, json!({ "bsd": disk.bsd }));
                spawn_auto_mount(&state, &disk.bsd);
            }
        }
        if requested {
            for disk in &disks {
                spawn_auto_mount(&state, &disk.bsd);
            }
        }
        for bsd in prev.difference(&cur) {
            info!("磁盘消失: {bsd}");
            cleanup_disappeared(&state, bsd);
        }
        prev = cur;
    }
}

fn disk_arbitration_event_loop(state: Arc<DaemonState>) {
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};

    while !state.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
        let mut child = match Command::new("/usr/sbin/diskutil")
            .arg("activity")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => child,
            Err(error) => {
                warn!("Disk Arbitration 监听启动失败: {error}");
                std::thread::sleep(std::time::Duration::from_secs(10));
                continue;
            }
        };
        if let Some(stdout) = child.stdout.take() {
            for line in BufReader::new(stdout).lines() {
                if state.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
                    break;
                }
                if line.is_ok() {
                    state
                        .rescan_requested
                        .store(true, std::sync::atomic::Ordering::SeqCst);
                }
            }
        }
        let _ = child.kill();
        let _ = child.wait();
        if !state.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
            warn!("Disk Arbitration 监听已退出，1s 后重连");
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }
}

fn mounted_partition_types(state: &DaemonState, bsd: &str) -> HashSet<u32> {
    let source = format!("/dev/r{bsd}");
    session::list_active(&state.session_root)
        .ok()
        .and_then(|value| value.get("sessions").and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .into_iter()
        .filter(|item| item.get("source").and_then(Value::as_str) == Some(source.as_str()))
        .filter_map(|item| {
            item.get("partition")
                .and_then(|partition| partition.get("partition_type"))
                .and_then(Value::as_u64)
                .map(|value| value as u32)
        })
        .collect()
}

fn maybe_auto_mount(state: &DaemonState, bsd: &str) -> EvaluationOutcome {
    if state.quiesced.load(std::sync::atomic::Ordering::SeqCst) {
        return EvaluationOutcome::Done;
    }
    let disk_info = edp_macos::list_disks(false)
        .ok()
        .and_then(|disks| disks.into_iter().find(|disk| disk.bsd == bsd));
    let Some(disk_info) = disk_info else {
        return EvaluationOutcome::Retry;
    };
    let detected = state
        .disk_inventory
        .lock()
        .unwrap()
        .get(bsd)
        .cloned()
        .or_else(|| inspect_disk(bsd, &disk_info.media_name, disk_info.total_size).ok());
    let Some(detected) = detected else {
        return EvaluationOutcome::Retry;
    };
    state
        .disk_inventory
        .lock()
        .unwrap()
        .entry(bsd.to_string())
        .or_insert_with(|| detected.clone());
    state.broadcaster.broadcast(
        edp_proto::event::DEVICE_DETECTED,
        json!({ "bsd": bsd, "kind": detected.kind }),
    );
    if detected.kind != "edp" {
        return EvaluationOutcome::Done;
    }

    let config = state.config.lock().unwrap().clone();
    if config.auto_mount_mode != AutoMountMode::Active {
        return EvaluationOutcome::Done;
    }
    let Some(policy) = config.policy(&detected.candidate_ids).cloned() else {
        state.broadcaster.broadcast(
            edp_proto::event::DEVICE_NEEDS_SETUP,
            json!({ "bsd": bsd, "candidate_ids": detected.candidate_ids }),
        );
        return EvaluationOutcome::Done;
    };
    if !policy.authorized {
        return EvaluationOutcome::Done;
    }

    let source = PathBuf::from(format!("/dev/r{bsd}"));
    let already_mounted = mounted_partition_types(state, bsd);
    let mut plans = Vec::new();
    for partition_type in &policy.partition_types {
        if already_mounted.contains(partition_type) {
            continue;
        }
        let records = state
            .keystore
            .lock()
            .unwrap()
            .candidates(&policy.device_id, *partition_type);
        for record in records {
            if let Ok((descriptor, hit_id, _)) = discover_verified(
                &source,
                Some(&policy.device_id),
                &record.password,
                *partition_type,
            ) {
                plans.push((descriptor, hit_id, record.id.clone(), record.label.clone()));
                break;
            }
        }
    }
    if plans.is_empty() {
        if !policy.partition_types.is_empty() && already_mounted.is_empty() {
            state.broadcaster.broadcast(
                edp_proto::event::PASSWORD_NEEDED,
                json!({ "bsd": bsd, "device_id": policy.device_id }),
            );
        }
        return EvaluationOutcome::Done;
    }

    let physical_already_prepared = !already_mounted.is_empty();
    let operation_id = uuid::Uuid::new_v4().to_string();
    if !physical_already_prepared {
        let started = std::time::Instant::now();
        let result = edp_macos::unmount_disk(bsd);
        record_timing(
            state,
            timing(
                &operation_id,
                "auto_mount",
                "physical_unmount",
                started,
                if result.is_ok() { "ok" } else { "error" },
                Some(&policy.device_id),
                None,
                result.as_ref().err().map(ToString::to_string),
            ),
        );
        if let Err(error) = result {
            state.broadcaster.broadcast(
                edp_proto::event::MOUNT_FAILED,
                json!({ "bsd": bsd, "message": error.to_string() }),
            );
            return EvaluationOutcome::Done;
        }
    }

    let mut mounted_any = false;
    for (descriptor, hit_id, record_id, label) in plans {
        info!(
            "自动挂载 {bsd} type={} label={label}",
            descriptor.partition_type
        );
        let started = std::time::Instant::now();
        match session::mount_and_attach(
            &source,
            &descriptor,
            &hit_id,
            false,
            None,
            None,
            &state.session_root,
        ) {
            Ok(session) => {
                if let Some(sid) = session.get("session_id").and_then(Value::as_str) {
                    record_timing(
                        state,
                        timing(
                            &operation_id,
                            "auto_mount",
                            "bridge_attach",
                            started,
                            "ok",
                            Some(&hit_id),
                            Some(sid),
                            None,
                        ),
                    );
                    mounted_any = true;
                    register_session(state, bsd, sid);
                    state
                        .broadcaster
                        .broadcast(edp_proto::event::MOUNTED, session);
                    if let Ok(mut keystore) = state.keystore.try_lock() {
                        keystore.touch(&record_id);
                    }
                }
            }
            Err(error) => {
                record_timing(
                    state,
                    timing(
                        &operation_id,
                        "auto_mount",
                        "bridge_attach",
                        started,
                        "error",
                        Some(&hit_id),
                        None,
                        Some(error.to_string()),
                    ),
                );
                state.broadcaster.broadcast(
                    edp_proto::event::MOUNT_FAILED,
                    json!({
                        "bsd": bsd,
                        "partition_type": descriptor.partition_type,
                        "message": error.to_string(),
                    }),
                )
            }
        }
    }
    if !mounted_any && !physical_already_prepared {
        let _ = edp_macos::mount_disk(bsd);
    }
    EvaluationOutcome::Done
}

fn cleanup_disappeared(state: &DaemonState, bsd: &str) {
    let sessions = state
        .mounted
        .lock()
        .unwrap()
        .remove(bsd)
        .unwrap_or_default();
    let session_ids: Vec<String> = sessions.into_iter().collect();
    for sid in &session_ids {
        info!("磁盘消失，清理会话 {sid}");
        if let Err(error) = session::unmount(sid, true, &state.session_root) {
            warn!("清理会话 {sid} 失败: {error}");
        }
    }
    state.disk_inventory.lock().unwrap().remove(bsd);
    // Always notify clients, including for ordinary, unauthorized and
    // password-missing disks that never created a session.
    state.broadcaster.broadcast(
        edp_proto::event::DISK_REMOVED,
        json!({ "bsd": bsd, "session_ids": session_ids }),
    );
}

#[cfg(test)]
mod safety_tests {
    use super::*;

    #[test]
    fn ordinary_sector_is_not_edp_even_if_an_unrelated_lba_has_dollar_marker() {
        // The old detector looked for "$$" in LBA4. The new detector never receives
        // LBA4 and requires a structurally valid EDPF table in LBA7.
        let mut ordinary_lba7 = [0u8; 512];
        ordinary_lba7[..8].copy_from_slice(b"FAT32   ");
        assert!(!lba7_is_structurally_edp(&ordinary_lba7, 64 * 1024 * 1024));
    }

    #[test]
    fn real_fixture_lba7_passes_strong_structure_check() {
        let bytes = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/real_disks/disk4/LBA7.bin"
        ))
        .unwrap();
        let lba7: [u8; 512] = bytes.try_into().unwrap();
        assert!(lba7_is_structurally_edp(&lba7, 124_736_503_808));
    }
}
