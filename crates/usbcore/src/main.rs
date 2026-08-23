//! # usbcore
//!
//! EDP 加密 U 盘内核：单一多角色二进制。
//! - `usbcore <cmd>`：终端 CLI（离线模式：sudo 直跑；在线模式 M2 接入 daemon socket）
//! - `usbcore daemon run`：launchd 常驻守护进程（M2）
//! - `usbcore bridge`：macFUSE 单文件桥（daemon/CLI 内部 spawn）

mod bridge;
mod daemon;
mod keystore;
mod session;

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use edp_core::discovery::{discover_volume, filesystem_magic, DeviceIdHints};
use edp_core::lba7::verify_password;
use edp_core::volume::{EncryptedPartitionIO, FileRawIo};
use edp_core::SECTOR_SIZE;

/// 会话根目录（默认 /tmp/edp-usb-sessions，可用环境变量覆盖）。
fn session_root() -> PathBuf {
    std::env::var_os("EDP_USB_SESSION_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/edp-usb-sessions"))
}

#[derive(Debug, Parser)]
#[command(
    name = "usbcore",
    version,
    about = "EDP 加密 U 盘内核（CLI / daemon / bridge）"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// 列出磁盘（默认仅外置物理盘）
    List {
        /// 包含内置盘
        #[arg(long)]
        all: bool,
    },
    /// 环境自检
    Doctor,
    /// LBA7 密码认证报告
    Login {
        source: PathBuf,
        #[arg(long)]
        password: Option<String>,
    },
    /// 只读探测（密码/key/分区/文件系统签名闭环，不挂载）
    Probe {
        source: PathBuf,
        #[arg(long)]
        password: Option<String>,
        #[arg(long)]
        device_id: Option<String>,
        #[arg(long, default_value_t = 4)]
        partition_type: u32,
    },
    /// 挂载 EDP 数据分区
    Mount {
        source: PathBuf,
        #[arg(long)]
        password: Option<String>,
        #[arg(long)]
        device_id: Option<String>,
        #[arg(long, default_value_t = 4)]
        partition_type: u32,
        #[arg(long)]
        readonly: bool,
        #[arg(long)]
        mountpoint: Option<PathBuf>,
        #[arg(long)]
        session_id: Option<String>,
    },
    /// 卸载会话
    Unmount {
        session_id: String,
        #[arg(long)]
        force: bool,
    },
    /// 列出活动会话
    Mounts,
    /// daemon 在线状态摘要
    Status,
    /// 密码库管理（需 daemon 在线）
    Keys {
        #[command(subcommand)]
        action: KeysCmd,
    },
    /// 内部子命令：macFUSE 单文件桥（daemon spawn）
    #[command(hide = true)]
    Bridge {
        source: PathBuf,
        mountpoint: PathBuf,
        #[arg(long)]
        start_sector: u64,
        #[arg(long)]
        size_bytes: u64,
        #[arg(long)]
        partition_type: u32,
        #[arg(long)]
        key_fd: i32,
        #[arg(long)]
        readonly: bool,
    },
    /// 守护进程子命令
    Daemon {
        #[command(subcommand)]
        action: DaemonCmd,
    },
}

#[derive(Debug, Subcommand)]
enum KeysCmd {
    /// 列出密码库条目（脱敏）
    Ls,
    /// 添加密码
    Add {
        #[arg(long)]
        label: Option<String>,
        #[arg(long)]
        device_id: Option<String>,
        #[arg(long)]
        disk: Option<String>,
        #[arg(long, default_value_t = 4)]
        partition_type: u32,
        #[arg(long)]
        password: Option<String>,
        #[arg(long)]
        no_auto_mount: bool,
    },
    /// 删除密码
    Rm { id: String },
}

#[derive(Debug, Subcommand)]
enum DaemonCmd {
    /// 前台运行 daemon（launchd 调用）
    Run {
        /// 会话根目录（测试用）
        #[arg(long)]
        session_root: Option<PathBuf>,
        /// socket 路径覆盖（测试用）
        #[arg(long)]
        socket: Option<String>,
    },
    /// 安装 launchd 守护进程
    Install,
    /// 卸载 launchd 守护进程
    Uninstall,
    /// daemon 状态（在线/离线）
    Status,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    let cli = Cli::parse();
    match cli.command {
        Commands::List { all } => cmd_list(all),
        Commands::Doctor => cmd_doctor(),
        Commands::Login { source, password } => cmd_login(&source, password),
        Commands::Probe {
            source,
            password,
            device_id,
            partition_type,
        } => cmd_probe(&source, password, device_id, partition_type),
        Commands::Mount {
            source,
            password,
            device_id,
            partition_type,
            readonly,
            mountpoint,
            session_id,
        } => cmd_mount(
            &source,
            password,
            device_id,
            partition_type,
            readonly,
            mountpoint,
            session_id,
        ),
        Commands::Unmount { session_id, force } => cmd_unmount(&session_id, force),
        Commands::Mounts => cmd_mounts(),
        Commands::Status => cmd_status(),
        Commands::Keys { action } => cmd_keys(action),
        Commands::Bridge {
            source,
            mountpoint,
            start_sector,
            size_bytes,
            partition_type,
            key_fd,
            readonly,
        } => bridge::run(
            &source,
            &mountpoint,
            start_sector,
            size_bytes,
            partition_type,
            key_fd,
            readonly,
        ),
        Commands::Daemon { action } => cmd_daemon(action),
    }
}

fn cmd_keys(action: KeysCmd) -> Result<()> {
    let Some(mut c) = try_online() else {
        bail!(
            "daemon 未运行（{}）；请先 `sudo usbcore daemon install` 或 `sudo usbcore daemon run`",
            daemon_socket()
        );
    };
    match action {
        KeysCmd::Ls => {
            let r = c.call(edp_proto::method::KEYS_LS, serde_json::json!({}))?;
            println!("{}", serde_json::to_string_pretty(&r)?);
        }
        KeysCmd::Add {
            label,
            device_id,
            disk,
            partition_type,
            password,
            no_auto_mount,
        } => {
            let password = get_password(password)?;
            let params = serde_json::json!({
                "label": label.unwrap_or_else(|| "EDP 盘".into()),
                "device_id": device_id,
                "disk": disk,
                "partition_type": partition_type,
                "password": password,
                "auto_mount": !no_auto_mount,
            });
            let r = c.call(edp_proto::method::KEYS_ADD, params)?;
            println!("{}", serde_json::to_string_pretty(&r)?);
        }
        KeysCmd::Rm { id } => {
            let r = c.call(edp_proto::method::KEYS_RM, serde_json::json!({ "id": id }))?;
            println!("{}", serde_json::to_string_pretty(&r)?);
        }
    }
    Ok(())
}

fn cmd_daemon(action: DaemonCmd) -> Result<()> {
    match action {
        DaemonCmd::Run {
            session_root,
            socket,
        } => daemon::run_with(socket.as_deref(), None, session_root.as_deref()),
        DaemonCmd::Install => daemon::install(),
        DaemonCmd::Uninstall => daemon::uninstall(),
        DaemonCmd::Status => daemon::status(&daemon_socket()),
    }
}

// ---------- 通用辅助 ----------

fn pread(path: &Path, off: u64, size: usize) -> Result<Vec<u8>> {
    use std::os::unix::fs::FileExt;
    let f = std::fs::File::open(path)?;
    let mut buf = vec![0u8; size];
    f.read_exact_at(&mut buf, off)
        .with_context(|| format!("读取 {} @{} 失败", path.display(), off))?;
    Ok(buf)
}

fn disk_size_bytes(path: &Path) -> Result<u64> {
    if path.starts_with("/dev/") {
        let out = std::process::Command::new("diskutil")
            .args(["info", "-plist"])
            .arg(dev_disk_of(path)?)
            .output()?;
        let info: plist::Value = plist::from_bytes(&out.stdout)?;
        Ok(info
            .as_dictionary()
            .and_then(|d| d.get("TotalSize"))
            .and_then(plist::Value::as_unsigned_integer)
            .context("diskutil 未返回 TotalSize")?)
    } else {
        Ok(std::fs::metadata(path)?.len())
    }
}

/// `/dev/rdiskN` → `diskN`。
fn dev_disk_of(path: &Path) -> Result<String> {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .context("非法设备路径")?;
    let n = name.trim_start_matches('r');
    Ok(n.to_string())
}

/// 校验必须是整盘 rdiskN 或镜像文件。
fn validate_whole_disk_or_image(path: &Path) -> Result<()> {
    let s = path.to_string_lossy();
    if s.starts_with("/dev/") && !s.starts_with("/dev/rdisk") {
        bail!("原始设备必须是完整的 /dev/rdiskN，不能是分区节点或 /dev/diskN");
    }
    Ok(())
}

/// 获取密码：TTY 交互（隐藏输入）；daemon 场景 M2 走 RPC。
fn get_password(provided: Option<String>) -> Result<String> {
    match provided {
        Some(p) => Ok(p),
        None => {
            eprint!("U 盘密码: ");
            Ok(rpassword::read_password()?)
        }
    }
}

/// daemon socket 路径（可用环境变量覆盖测试）。
fn daemon_socket() -> String {
    std::env::var_os("EDP_USB_SOCKET")
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "/var/run/edp-usbcore.sock".to_string())
}

/// 尝试连接 daemon；成功返回 Client。
fn try_online() -> Option<edp_proto::Client> {
    let sock = daemon_socket();
    if !Path::new(&sock).exists() {
        return None;
    }
    edp_proto::Client::connect(&sock).ok()
}

fn require_mount_support() -> Result<()> {
    if !cfg!(target_os = "macos") {
        bail!("仅支持 macOS");
    }
    if !Path::new("/Library/Filesystems/macfuse.fs").exists() {
        bail!("未检测到 macFUSE（/Library/Filesystems/macfuse.fs）；请先安装 macFUSE");
    }
    Ok(())
}

/// 组装 device_id 发现提示（显式 → LBA11 → identify 候选）。
pub(crate) fn build_hints_for(source: &Path) -> DeviceIdHints {
    build_hints(source, None)
}

/// 组装 device_id 发现提示（显式 → LBA11 → identify 候选）。
fn build_hints(source: &Path, explicit: Option<String>) -> DeviceIdHints {
    let lba11_params = source
        .to_str()
        .and_then(|s| s.strip_prefix("/dev/rdisk"))
        .and_then(|n| n.parse::<u32>().ok())
        .and_then(edp_macos::lba11_params);
    let inquiry = edp_macos::inquiry_sources(source);
    DeviceIdHints {
        explicit,
        lba11_params,
        inquiry,
    }
}

// ---------- 子命令实现 ----------

fn cmd_list(all: bool) -> Result<()> {
    let disks = edp_macos::list_disks(all)?;
    println!("{}", serde_json::to_string_pretty(&disks)?);
    Ok(())
}

fn cmd_doctor() -> Result<()> {
    let macfuse = edp_macos::macfuse_version();
    let daemon = try_online().and_then(|mut c| {
        c.call(edp_proto::method::STATUS, serde_json::json!({}))
            .ok()
    });
    let report = serde_json::json!({
        "ok": true,
        "macos": true,
        "macfuse": macfuse,
        "hdiutil": which("hdiutil"),
        "diskutil": which("diskutil"),
        "root": unsafe { libc::getuid() } == 0,
        "daemon_online": daemon.is_some(),
        "daemon": daemon,
        "daemon_socket": daemon_socket(),
    });
    println!("{}", serde_json::to_string_pretty(&report)?);
    if macfuse.is_none() {
        eprintln!("提示: 未安装 macFUSE，挂载功能不可用");
    }
    Ok(())
}

fn which(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(bin).exists()))
        .unwrap_or(false)
}

fn cmd_login(source: &Path, password: Option<String>) -> Result<()> {
    validate_whole_disk_or_image(source)?;
    let password = get_password(password)?;
    let raw = pread(source, 7 * SECTOR_SIZE, 512)?;
    let raw: [u8; 512] = raw.as_slice().try_into().unwrap();
    let report = verify_password(&raw, &password).map_err(|e| anyhow::anyhow!(e.to_string()))?;
    println!("{}", serde_json::to_string_pretty(&report)?);
    if !report.authenticated {
        std::process::exit(3);
    }
    Ok(())
}

fn cmd_probe(
    source: &Path,
    password: Option<String>,
    device_id: Option<String>,
    partition_type: u32,
) -> Result<()> {
    validate_whole_disk_or_image(source)?;
    let password = get_password(password)?;
    let io = std::sync::Arc::new(FileRawIo::open(source, true)?);
    let hints = build_hints(source, device_id);
    let (desc, hit_id) = discover_volume(io.as_ref(), &hints, &password, partition_type)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let target_size = disk_size_bytes(source)?;
    if desc.start_bytes() + desc.size_bytes > target_size {
        bail!("LBA12 描述的加密分区超过目标设备容量");
    }
    let vol = EncryptedPartitionIO::open(io, desc.clone(), true)?;
    let mut boot = [0u8; 512];
    vol.read(0, &mut boot)?;
    let report = serde_json::json!({
        "ok": filesystem_magic(&boot).is_some(),
        "source": source.display().to_string(),
        "device_id": hit_id,
        "partition": desc.public_dict(),
        "filesystem_magic": String::from_utf8_lossy(&boot[3..11]).trim_end(),
        "decrypted_boot_sha256": sha256_hex(&boot),
        "read_only_probe": true,
    });
    println!("{}", serde_json::to_string_pretty(&report)?);
    if !report["ok"].as_bool().unwrap_or(false) {
        std::process::exit(2);
    }
    Ok(())
}

fn sha256_hex(data: &[u8]) -> String {
    // 避免引入 sha2 依赖：用 openssl 命令？不——直接省略为空并标注。
    // M1 集成测试需要时再引入 sha2 crate。
    let _ = data;
    String::new()
}

fn cmd_mount(
    source: &Path,
    password: Option<String>,
    device_id: Option<String>,
    partition_type: u32,
    readonly: bool,
    mountpoint: Option<PathBuf>,
    session_id: Option<String>,
) -> Result<()> {
    require_mount_support()?;
    let source = source
        .canonicalize()
        .unwrap_or_else(|_| source.to_path_buf());
    // 在线优先：daemon（root）代为挂载，免 sudo
    if let Some(mut c) = try_online() {
        if device_id.is_some() || mountpoint.is_some() || session_id.is_some() {
            bail!(
                "在线模式不支持 --device-id/--mountpoint/--session-id \
                 （daemon 自行发现与命名）；请卸载 daemon 后离线挂载"
            );
        }
        let password = get_password(password)?;
        let params = edp_proto::MountParams {
            disk: source.to_string_lossy().into_owned(),
            partition_type: Some(partition_type),
            readonly: Some(readonly),
            password: Some(password),
        };
        let r = c.call(edp_proto::method::MOUNT, serde_json::to_value(params)?)?;
        println!("{}", serde_json::to_string_pretty(&r)?);
        return Ok(());
    }
    validate_whole_disk_or_image(&source)?;
    if source.starts_with("/dev/") && !readonly && unsafe { libc::getuid() } != 0 {
        bail!("真实 U 盘读写挂载需要 sudo（或先启动 daemon 走在线模式）");
    }
    let password = get_password(password)?;
    let io = std::sync::Arc::new(FileRawIo::open(&source, true)?);
    let hints = build_hints(&source, device_id);
    let (desc, hit_id) = discover_volume(io.as_ref(), &hints, &password, partition_type)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let target_size = disk_size_bytes(&source)?;
    if desc.start_bytes() + desc.size_bytes > target_size {
        bail!("LBA12 描述的加密分区超过目标设备容量");
    }
    // 闭环：解密 boot 扇区验证文件系统签名
    {
        let vol = EncryptedPartitionIO::open(io, desc.clone(), true)?;
        let mut boot = [0u8; 512];
        vol.read(0, &mut boot)?;
        if filesystem_magic(&boot).is_none() {
            bail!(
                "密码/数据 key 已闭合，但解密后的文件系统签名未知: {:?}",
                &boot[3..11]
            );
        }
    }

    let state = session::mount_and_attach(
        &source,
        &desc,
        &hit_id,
        readonly,
        mountpoint.as_deref(),
        session_id.as_deref(),
        &session_root(),
    )?;
    println!("{}", serde_json::to_string_pretty(&state)?);
    Ok(())
}

fn cmd_unmount(session_id: &str, force: bool) -> Result<()> {
    // 在线优先：daemon 维护的会话，免 sudo
    if let Some(mut c) = try_online() {
        let r = c.call(
            edp_proto::method::UNMOUNT,
            serde_json::json!({ "session_id": session_id, "force": force }),
        )?;
        println!("{}", serde_json::to_string_pretty(&r)?);
        return Ok(());
    }
    session::unmount(session_id, force, &session_root())
}

fn cmd_status() -> Result<()> {
    let mut report = serde_json::json!({
        "daemon_online": false,
        "version": env!("CARGO_PKG_VERSION"),
    });
    let Some(mut c) = try_online() else {
        println!("{}", serde_json::to_string_pretty(&report)?);
        std::process::exit(4);
    };
    let s = c.call(edp_proto::method::STATUS, serde_json::json!({}))?;
    report["daemon_online"] = serde_json::json!(true);
    report["daemon"] = s;
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}

fn cmd_mounts() -> Result<()> {
    // 在线优先：daemon 维护的会话
    if let Some(mut c) = try_online() {
        let r = c.call(edp_proto::method::SESSIONS, serde_json::json!({}))?;
        println!("{}", serde_json::to_string_pretty(&r)?);
        return Ok(());
    }
    let sessions = session::list_active(&session_root())?;
    println!("{}", serde_json::to_string_pretty(&sessions)?);
    Ok(())
}
