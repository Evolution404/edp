//! daemon：launchd 常驻守护进程。
//!
//! 职责：磁盘事件监听 → EDP 盘识别 → keystore 密码匹配 → 自动挂载；
//! 通过 UDS JSON-RPC 服务 CLI / GUI。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tracing::{info, warn};

use edp_core::discovery::{discover_volume, filesystem_magic};
use edp_core::volume::FileRawIo;
use edp_proto::{serve, EventBroadcaster, Handler};

use crate::keystore::Keystore;
use crate::session;

/// daemon 全局状态（注入 RPC Context）。
pub struct DaemonState {
    pub keystore: Mutex<Keystore>,
    pub config: Mutex<Config>,
    pub broadcaster: EventBroadcaster,
    pub session_root: PathBuf,
    pub started_at: std::time::Instant,
    /// 当前已挂载会话的 bsd → session_id
    pub mounted: Mutex<HashMap<String, String>>,
    /// 识别到的 EDP 盘（bsd → device_id）
    pub edp_disks: Mutex<HashMap<String, String>>,
}

/// 运行配置。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Config {
    pub auto_mount_enabled: bool,
    /// 自动挂载默认分区类型（2=交换区 4=保密区）；null 表示全部匹配的都要挂。
    pub default_partition_types: Vec<u32>,
    pub socket_path: String,
    pub allowed_uids: Vec<u32>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            auto_mount_enabled: true,
            default_partition_types: vec![4],
            socket_path: "/var/run/edp-usbcore.sock".to_string(),
            allowed_uids: Vec::new(),
        }
    }
}

const DEFAULT_SESSION_ROOT: &str = "/var/db/edp-usbcore/sessions";

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
    let mut cfg = load_config(config_path).unwrap_or_default();
    if let Some(sock) = socket_override {
        cfg.socket_path = sock.to_string();
    }
    let session_root = session_root_override
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(DEFAULT_SESSION_ROOT));
    std::fs::create_dir_all(&session_root)?;

    let keystore_dir = session_root
        .parent()
        .unwrap_or(Path::new("/var/db/edp-usbcore"));
    let ks = Keystore::open(keystore_dir)?;
    let broadcaster = EventBroadcaster::new();

    let state = Arc::new(DaemonState {
        keystore: Mutex::new(ks),
        config: Mutex::new(cfg.clone()),
        broadcaster: broadcaster.clone(),
        session_root,
        started_at: std::time::Instant::now(),
        mounted: Mutex::new(HashMap::new()),
        edp_disks: Mutex::new(HashMap::new()),
    });

    // 启动磁盘监听线程（轮询 diskutil diff；DiskArbitration 后续补）
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
    let handle = serve(
        &cfg.socket_path,
        methods,
        allowed_uids,
        state.clone() as Arc<dyn std::any::Any + Send + Sync>,
    )
    .with_context(|| format!("监听 {} 失败", cfg.socket_path))?;

    info!(
        "usbcore daemon 就绪: socket={} keystore_ok=true auto_mount={}",
        cfg.socket_path, cfg.auto_mount_enabled
    );

    // 主线程常驻（launchd 管理生命周期；收到 SIGTERM 由系统处理）
    let mut handle = handle;
    std::thread::park();
    handle.shutdown();
    Ok(())
}

fn load_config(path: Option<&Path>) -> Option<Config> {
    let p = path.unwrap_or(Path::new("/var/db/edp-usbcore/config.json"));
    let text = std::fs::read_to_string(p).ok()?;
    serde_json::from_str(&text).ok()
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
    Ok(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "uptime_s": d.started_at.elapsed().as_secs(),
        "macfuse": edp_macos::macfuse_version(),
        "keystore_ok": true,
        "keystore_entries": ks.all().len(),
        "auto_mount_enabled": cfg.auto_mount_enabled,
        "mounted_sessions": d.mounted.lock().unwrap().len(),
    }))
}

fn handle_list_disks(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    let all = p.get("all").and_then(|x| x.as_bool()).unwrap_or(false);
    let disks = edp_macos::list_disks(!all).map_err(rpc_io)?;
    let mounted = d.mounted.lock().unwrap();
    let edp = d.edp_disks.lock().unwrap();
    let out: Vec<Value> = disks
        .into_iter()
        .map(|dk| {
            json!({
                "bsd": dk.bsd,
                "rbsd": dk.rbsd,
                "size": dk.total_size,
                "media_name": dk.media_name,
                "is_edp": edp.get(&dk.bsd).is_some(),
                "session_id": mounted.get(&dk.bsd),
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
    let io = std::sync::Arc::new(FileRawIo::open(source, true)?);
    let hints = crate::build_hints_for(source);
    let (desc, hit_id) = discover_volume(io.as_ref(), &hints, password, ptype)?;
    let vol = edp_core::volume::EncryptedPartitionIO::open(io, desc.clone(), true)?;
    let mut boot = [0u8; 512];
    vol.read(0, &mut boot)?;
    Ok(json!({
        "ok": filesystem_magic(&boot).is_some(),
        "device_id": hit_id,
        "partition": desc.public_dict(),
        "filesystem_magic": String::from_utf8_lossy(&boot[3..11]).trim_end(),
    }))
}

fn handle_mount(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
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
            match discover_volume(io.as_ref(), &hints, &rec.password, ptype) {
                Ok((desc, id)) => {
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
        let (desc, id) = discover_volume(io.as_ref(), &hints, password, ptype)
            .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
        (desc, id, String::new())
    };

    let session_root = d.session_root.clone();
    let state =
        session::mount_and_attach(&source, &desc, &hit_id, readonly, None, None, &session_root)
            .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
    if let Some(sid) = state["session_id"].as_str() {
        d.mounted
            .lock()
            .unwrap()
            .insert(disk.to_string(), sid.to_string());
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
    let sid = p
        .get("session_id")
        .and_then(|x| x.as_str())
        .unwrap_or_default();
    let force = p.get("force").and_then(|x| x.as_bool()).unwrap_or(false);
    let session_root = d.session_root.clone();
    session::unmount(sid, force, &session_root)
        .map_err(|e| edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string()))?;
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
                "auto_mount": r.auto_mount,
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
    let auto_mount = p
        .get("auto_mount")
        .and_then(|x| x.as_bool())
        .unwrap_or(true);
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
        let io = std::sync::Arc::new(FileRawIo::open(&source, true).map_err(rpc_io)?);
        let hints = crate::build_hints_for(&source);
        let (_, hit) = discover_volume(io.as_ref(), &hints, &password, partition_type)
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
            auto_mount,
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
    Ok(serde_json::to_value(&*cfg).unwrap())
}

fn handle_config_set(ctx: &edp_proto::Context, p: Value) -> Result<Value, edp_proto::RpcError> {
    let d = daemon(ctx)?;
    if !ctx.is_root() {
        return Err(edp_proto::RpcError::new(
            edp_proto::codes::PERMISSION_DENIED,
            "仅 root 可改配置",
        ));
    }
    let mut cfg = d.config.lock().unwrap();
    if let Some(b) = p.get("auto_mount_enabled").and_then(|x| x.as_bool()) {
        cfg.auto_mount_enabled = b;
    }
    if let Some(v) = p.get("default_partition_types").and_then(|x| x.as_array()) {
        cfg.default_partition_types = v
            .iter()
            .filter_map(|x| x.as_u64())
            .map(|x| x as u32)
            .collect();
    }
    let cfg_json = serde_json::to_value(&*cfg).unwrap();
    drop(cfg);
    // 持久化
    let path = Path::new("/var/db/edp-usbcore/config.json");
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    if let Ok(text) = serde_json::to_string_pretty(&cfg_json) {
        let _ = std::fs::write(path, text);
    }
    Ok(cfg_json)
}

fn rpc_io(e: std::io::Error) -> edp_proto::RpcError {
    edp_proto::RpcError::new(edp_proto::codes::INTERNAL, e.to_string())
}

// ---------- launchd 管理 ----------

const LAUNCHD_LABEL: &str = "com.edp.usbcore";
const PLIST_PATH: &str = "/Library/LaunchDaemons/com.edp.usbcore.plist";
const BIN_INSTALL_PATH: &str = "/usr/local/libexec/usbcore";
const BIN_SYMLINK: &str = "/usr/local/bin/usbcore";

/// 安装 launchd 守护进程（需 root）。
pub fn install() -> Result<()> {
    if unsafe { libc::getuid() } != 0 {
        bail!("安装守护进程需要 root：请用 sudo 运行 usbcore daemon install");
    }
    let self_exe = std::env::current_exe()?;
    // 复制二进制到 /usr/local/libexec
    std::fs::create_dir_all("/usr/local/libexec")?;
    std::fs::create_dir_all("/usr/local/bin")?;
    std::fs::copy(&self_exe, BIN_INSTALL_PATH)?;
    let _ = std::fs::remove_file(BIN_SYMLINK);
    std::os::unix::fs::symlink(BIN_INSTALL_PATH, BIN_SYMLINK)?;
    // 初始化数据目录
    std::fs::create_dir_all("/var/db/edp-usbcore/logs")?;
    std::fs::create_dir_all("/var/db/edp-usbcore/sessions")?;
    // 持久化初始配置（授权控制台用户；socket 用系统默认路径）
    let initial_cfg = Config {
        socket_path: "/var/run/edp-usbcore.sock".to_string(),
        allowed_uids: default_allowed_uids(),
        ..Config::default()
    };
    let _ = std::fs::write(
        "/var/db/edp-usbcore/config.json",
        serde_json::to_string_pretty(&initial_cfg)?,
    );
    // 写 plist
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>{BIN}</string><string>daemon</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/var/db/edp-usbcore/logs/daemon.out</string>
  <key>StandardErrorPath</key><string>/var/db/edp-usbcore/logs/daemon.err</string>
</dict></plist>
"#,
        LABEL = LAUNCHD_LABEL,
        BIN = BIN_INSTALL_PATH
    );
    std::fs::write(PLIST_PATH, plist)?;
    // 加载
    let out = std::process::Command::new("launchctl")
        .args(["bootstrap", "system", PLIST_PATH])
        .output()
        .context("launchctl bootstrap 失败")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        // 已加载时 bootstrap 会报错，尝试 bootout 后重载
        if !err.contains("already loaded") && !err.contains("Bootstrap failed: 5") {
            bail!("launchctl bootstrap: {err}");
        }
        let _ = std::process::Command::new("launchctl")
            .args(["bootout", "system", LAUNCHD_LABEL])
            .output();
        let out = std::process::Command::new("launchctl")
            .args(["bootstrap", "system", PLIST_PATH])
            .output()?;
        if !out.status.success() {
            bail!(
                "重新 bootstrap 失败: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
    }
    // 健康检查：等 socket 出现
    let sock = "/var/run/edp-usbcore.sock";
    for _ in 0..20 {
        if Path::new(sock).exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(300));
    }
    if !Path::new(sock).exists() {
        bail!("daemon 启动后 socket 未出现，请查看 /var/db/edp-usbcore/logs/daemon.err");
    }
    println!("daemon 已安装并启动：{sock}");
    Ok(())
}

/// 卸载 launchd 守护进程（需 root）。
pub fn uninstall() -> Result<()> {
    if unsafe { libc::getuid() } != 0 {
        bail!("卸载守护进程需要 root：请用 sudo 运行 usbcore daemon uninstall");
    }
    let _ = std::process::Command::new("launchctl")
        .args(["bootout", "system", LAUNCHD_LABEL])
        .output();
    let _ = std::fs::remove_file(PLIST_PATH);
    let _ = std::fs::remove_file("/var/run/edp-usbcore.sock");
    println!("daemon 已卸载");
    Ok(())
}

/// daemon 状态。
pub fn status(socket: &str) -> Result<()> {
    // 真实连通性检查（socket 文件存在但 daemon 已死 → 视为离线）
    let live = match edp_proto::Client::connect(socket) {
        Ok(mut c) => c.call(edp_proto::method::STATUS, json!({})).ok(),
        Err(_) => None,
    };
    let mut report = json!({
        "online": live.is_some(),
        "socket": socket,
        "macfuse": edp_macos::macfuse_version(),
    });
    if let Some(r) = live {
        report["status"] = r;
    }
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}

// ---------- 磁盘监听（轮询 diff） ----------

fn disk_watcher_loop(state: Arc<DaemonState>) {
    let mut prev: HashMap<String, bool> = HashMap::new();
    loop {
        let disks = edp_macos::list_disks(false).unwrap_or_default();
        let cur: HashMap<String, bool> = disks.iter().map(|d| (d.bsd.clone(), true)).collect();
        // appeared
        for bsd in cur.keys() {
            if !prev.contains_key(bsd) {
                info!("磁盘出现: {bsd}");
                state
                    .broadcaster
                    .broadcast(edp_proto::event::DISK_APPEARED, json!({ "bsd": bsd }));
                maybe_auto_mount(&state, bsd);
            }
        }
        // disappeared
        for bsd in prev.keys() {
            if !cur.contains_key(bsd) {
                info!("磁盘消失: {bsd}");
                cleanup_disappeared(&state, bsd);
            }
        }
        prev = cur;
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
}

fn maybe_auto_mount(state: &Arc<DaemonState>, bsd: &str) {
    let cfg = state.config.lock().unwrap();
    if !cfg.auto_mount_enabled {
        return;
    }
    let types = cfg.default_partition_types.clone();
    drop(cfg);
    let source = PathBuf::from(format!("/dev/r{bsd}"));
    // 读取 LBA4 判断 EDP 盘
    let is_edp = {
        use std::os::unix::fs::FileExt;
        if let Ok(f) = std::fs::File::open(&source) {
            let mut buf = [0u8; 512];
            if f.read_exact_at(&mut buf, 4 * 512).is_ok() {
                buf[..32].windows(2).any(|w| w == b"$$")
            } else {
                false
            }
        } else {
            false
        }
    };
    if !is_edp {
        return;
    }
    // 先 unmountDisk 清公共区
    let _ = edp_macos::unmount_disk(bsd);

    // 对每个默认分区类型，尝试 keystore 匹配
    for ptype in types {
        let io = match FileRawIo::open(&source, true) {
            Ok(f) => std::sync::Arc::new(f),
            Err(_) => continue,
        };
        let hints = crate::build_hints_for(&source);
        // 先解 device_id（keystore 匹配键）
        let device_id = {
            let io2 = io.clone();
            let ids = edp_core::discovery::candidate_device_ids(io2.as_ref(), &hints);
            ids.into_iter().next()
        };
        let Some(device_id) = device_id else {
            continue;
        };
        let candidates = state.keystore.lock().unwrap().candidates(&device_id, ptype);
        for rec in candidates {
            if !rec.auto_mount {
                continue;
            }
            // 密码双路径验证：probe 闭环
            let ok = probe_impl(&source, &rec.password, ptype).is_ok();
            if ok {
                info!("自动挂载 {bsd} type={ptype} label={}", rec.label);
                let session_root = state.session_root.clone();
                let (desc, hit_id) =
                    match discover_volume(io.as_ref(), &hints, &rec.password, ptype) {
                        Ok(x) => x,
                        Err(e) => {
                            warn!("{bsd} 自动挂载 discover 失败: {e}");
                            continue;
                        }
                    };
                match session::mount_and_attach(
                    &source,
                    &desc,
                    &hit_id,
                    false,
                    None,
                    None,
                    &session_root,
                ) {
                    Ok(s) => {
                        if let Some(sid) = s["session_id"].as_str() {
                            state
                                .mounted
                                .lock()
                                .unwrap()
                                .insert(bsd.to_string(), sid.to_string());
                            state
                                .edp_disks
                                .lock()
                                .unwrap()
                                .insert(bsd.to_string(), device_id.clone());
                            state
                                .broadcaster
                                .broadcast(edp_proto::event::MOUNTED, s.clone());
                            if let Ok(mut ks) = state.keystore.try_lock() {
                                ks.touch(&rec.id);
                            }
                        }
                    }
                    Err(e) => warn!("{bsd} 自动挂载失败: {e}"),
                }
                break;
            }
        }
    }
}

fn cleanup_disappeared(state: &Arc<DaemonState>, bsd: &str) {
    if let Some(sid) = state.mounted.lock().unwrap().remove(bsd) {
        info!("磁盘消失，清理会话 {sid}");
        let session_root = state.session_root.clone();
        if let Err(e) = session::unmount(&sid, true, &session_root) {
            warn!("清理会话 {sid} 失败: {e}");
        }
        state.broadcaster.broadcast(
            edp_proto::event::DISK_REMOVED,
            json!({ "bsd": bsd, "session_id": sid }),
        );
    }
    state.edp_disks.lock().unwrap().remove(bsd);
}
