//! # usbcore
//!
//! EDP 加密 U 盘内核：单一多角色二进制。
//! - `usbcore <cmd>`：终端 CLI（M1）
//! - `usbcore daemon run`：launchd 常驻守护进程（M2）
//! - `usbcore bridge`：macFUSE 单文件桥（M1，daemon 内部 spawn）

use clap::Parser;

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

#[derive(Debug, clap::Subcommand)]
enum Commands {
    /// 列出磁盘（默认仅外置物理盘）
    List,
    /// 环境自检：macOS / macFUSE / hdiutil / diskutil / daemon 状态
    Doctor,
    /// 显示版本与构建信息
    Version,
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    let cli = Cli::parse();
    match cli.command {
        Commands::List => {
            println!("（M1 实现：usbcore list）");
            Ok(())
        }
        Commands::Doctor => {
            println!("usbcore {} — doctor（M1 实现）", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Commands::Version => {
            println!("usbcore {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
    }
}
