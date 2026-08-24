//! 仅供开发/诊断使用的分层性能基准。

use std::fs::{File, OpenOptions};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use clap::{Subcommand, ValueEnum};
use edp_proto::BenchmarkReport;

const HIKSEMI_SERIAL: &str = "7A6726BC6646D8C2";
const HIKSEMI_VENDOR: &str = "0x2bdf";
const HIKSEMI_PRODUCT: &str = "0x0300";
const RAW_OFFSET: u64 = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum BenchMode {
    Read,
    Write,
    ReadWrite,
}

#[derive(Debug, Subcommand)]
pub enum PerfCmd {
    /// 纯 SM4 原地加/解密基准。
    Sm4 {
        #[arg(long, default_value_t = 1024)]
        mib: u64,
        #[arg(long, default_value_t = 3)]
        iterations: u32,
        #[arg(long)]
        json: bool,
    },
    /// 普通文件/已挂载 EDP 卷基准。
    File {
        path: PathBuf,
        #[arg(long, value_enum, default_value_t = BenchMode::ReadWrite)]
        mode: BenchMode,
        #[arg(long, default_value_t = 32)]
        gib: u64,
        #[arg(long, default_value_t = 1024)]
        block_kib: u64,
        #[arg(long, default_value_t = 1)]
        queue_depth: usize,
        #[arg(long)]
        filesystem: Option<String>,
        #[arg(long, default_value = "native_file")]
        layer: String,
        /// 写测试必须显式确认；目标文件会被覆盖。
        #[arg(long)]
        destructive: bool,
        #[arg(long)]
        json: bool,
    },
    /// HIKSEMI 专用盘裸设备基准（三重身份校验）。
    HiksemiRaw {
        #[arg(long, value_enum, default_value_t = BenchMode::ReadWrite)]
        mode: BenchMode,
        #[arg(long, default_value_t = 32)]
        gib: u64,
        #[arg(long, default_value_t = 1024)]
        block_kib: u64,
        #[arg(long, default_value_t = 1)]
        queue_depth: usize,
        #[arg(long, default_value = HIKSEMI_SERIAL)]
        serial: String,
        #[arg(long, default_value = HIKSEMI_VENDOR)]
        vendor_id: String,
        #[arg(long, default_value = HIKSEMI_PRODUCT)]
        product_id: String,
        /// 写裸扇区必须显式确认。
        #[arg(long)]
        destructive: bool,
        #[arg(long)]
        json: bool,
    },
}

pub fn run(command: PerfCmd) -> Result<()> {
    match command {
        PerfCmd::Sm4 {
            mib,
            iterations,
            json,
        } => sm4_benchmark(mib, iterations, json),
        PerfCmd::File {
            path,
            mode,
            gib,
            block_kib,
            queue_depth,
            filesystem,
            layer,
            destructive,
            json,
        } => {
            if matches!(mode, BenchMode::Write | BenchMode::ReadWrite) && !destructive {
                bail!("写基准会覆盖目标文件，必须传入 --destructive");
            }
            let bytes = gib_to_bytes(gib)?;
            let file = open_benchmark_file(&path, mode, bytes)?;
            disable_cache(&file);
            let reports = benchmark_io(
                Arc::new(file),
                0,
                bytes,
                block_kib * 1024,
                queue_depth,
                mode,
                path.display().to_string(),
                &layer,
                filesystem,
            )?;
            print_reports(&reports, json)
        }
        PerfCmd::HiksemiRaw {
            mode,
            gib,
            block_kib,
            queue_depth,
            serial,
            vendor_id,
            product_id,
            destructive,
            json,
        } => {
            if matches!(mode, BenchMode::Write | BenchMode::ReadWrite) && !destructive {
                bail!("裸写会破坏 HIKSEMI 上的文件系统，必须传入 --destructive");
            }
            let identity = locate_hiksemi(&serial, &vendor_id, &product_id)?;
            validate_external_physical(&identity.bsd)?;
            let bytes = gib_to_bytes(gib)?;
            if RAW_OFFSET.saturating_add(bytes) > identity.size {
                bail!("基准范围超过设备容量 {}", identity.size);
            }
            let status = std::process::Command::new("/usr/sbin/diskutil")
                .args(["unmountDisk", &identity.bsd])
                .status()?;
            if !status.success() {
                bail!("无法卸载 {}，拒绝进行裸设备基准", identity.bsd);
            }
            let raw = format!("/dev/r{}", identity.bsd);
            let file = OpenOptions::new()
                .read(true)
                .write(matches!(mode, BenchMode::Write | BenchMode::ReadWrite))
                .open(&raw)
                .with_context(|| format!("打开 {raw} 失败（裸盘测试需 root）"))?;
            disable_cache(&file);
            let reports = benchmark_io(
                Arc::new(file),
                RAW_OFFSET,
                bytes,
                block_kib * 1024,
                queue_depth,
                mode,
                format!("HIKSEMI serial={serial} bsd={}", identity.bsd),
                "raw_device",
                None,
            )?;
            print_reports(&reports, json)
        }
    }
}

fn gib_to_bytes(gib: u64) -> Result<u64> {
    gib.checked_mul(1024 * 1024 * 1024)
        .filter(|bytes| *bytes > 0)
        .context("测试大小无效")
}

fn open_benchmark_file(path: &Path, mode: BenchMode, bytes: u64) -> Result<File> {
    let writing = matches!(mode, BenchMode::Write | BenchMode::ReadWrite);
    let file = OpenOptions::new()
        .read(true)
        .write(writing)
        .create(writing)
        .truncate(writing)
        .open(path)?;
    if writing {
        file.set_len(bytes)?;
    } else if file.metadata()?.len() < bytes {
        bail!("读基准文件小于指定测试大小");
    }
    Ok(file)
}

#[cfg(target_os = "macos")]
fn disable_cache(file: &File) {
    use std::os::fd::AsRawFd;
    unsafe {
        libc::fcntl(file.as_raw_fd(), libc::F_NOCACHE, 1);
    }
}

#[cfg(not(target_os = "macos"))]
fn disable_cache(_file: &File) {}

#[allow(clippy::too_many_arguments)]
fn benchmark_io(
    file: Arc<File>,
    offset: u64,
    bytes: u64,
    block_size: u64,
    queue_depth: usize,
    mode: BenchMode,
    identity: String,
    layer: &str,
    filesystem: Option<String>,
) -> Result<Vec<BenchmarkReport>> {
    if block_size == 0 || block_size % 4096 != 0 || bytes % block_size != 0 {
        bail!("测试大小必须是 block size 的整数倍，block size 必须 4KiB 对齐");
    }
    if !(1..=64).contains(&queue_depth) {
        bail!("queue depth 必须在 1..=64");
    }
    let mut reports = Vec::new();
    if matches!(mode, BenchMode::Write | BenchMode::ReadWrite) {
        reports.push(run_phase(
            file.clone(),
            offset,
            bytes,
            block_size,
            queue_depth,
            true,
            false,
            identity.clone(),
            layer,
            filesystem.clone(),
        )?);
        file.sync_all()?;
    }
    if matches!(mode, BenchMode::Read | BenchMode::ReadWrite) {
        reports.push(run_phase(
            file,
            offset,
            bytes,
            block_size,
            queue_depth,
            false,
            matches!(mode, BenchMode::ReadWrite),
            identity,
            layer,
            filesystem,
        )?);
    }
    Ok(reports)
}

#[allow(clippy::too_many_arguments)]
fn run_phase(
    file: Arc<File>,
    offset: u64,
    bytes: u64,
    block_size: u64,
    queue_depth: usize,
    write: bool,
    verify: bool,
    identity: String,
    layer: &str,
    filesystem: Option<String>,
) -> Result<BenchmarkReport> {
    let blocks = bytes / block_size;
    let next = Arc::new(AtomicU64::new(0));
    let failed = Arc::new(AtomicBool::new(false));
    let latencies = Arc::new(Mutex::new(Vec::with_capacity(blocks as usize)));
    let cpu_before = cpu_seconds();
    let started = Instant::now();
    let threads: Vec<_> = (0..queue_depth)
        .map(|_| {
            let file = file.clone();
            let next = next.clone();
            let failed = failed.clone();
            let latencies = latencies.clone();
            std::thread::spawn(move || {
                let mut buffer = vec![0u8; block_size as usize];
                let mut local_latencies = Vec::new();
                loop {
                    let block = next.fetch_add(1, Ordering::Relaxed);
                    if block >= blocks || failed.load(Ordering::Relaxed) {
                        break;
                    }
                    let position = offset + block * block_size;
                    if write {
                        fill_pattern(block, &mut buffer);
                    }
                    let operation_started = Instant::now();
                    let result = if write {
                        file.write_all_at(&buffer, position)
                    } else {
                        file.read_exact_at(&mut buffer, position)
                    };
                    local_latencies.push(operation_started.elapsed().as_micros() as u64);
                    if result.is_err() {
                        failed.store(true, Ordering::Relaxed);
                        break;
                    }
                    if verify {
                        let mut expected = vec![0u8; buffer.len()];
                        fill_pattern(block, &mut expected);
                        if buffer != expected {
                            failed.store(true, Ordering::Relaxed);
                            break;
                        }
                    }
                }
                latencies.lock().unwrap().extend(local_latencies);
            })
        })
        .collect();
    for thread in threads {
        thread
            .join()
            .map_err(|_| anyhow::anyhow!("基准线程 panic"))?;
    }
    if failed.load(Ordering::Relaxed) {
        bail!("I/O 失败或数据校验不一致");
    }
    let elapsed = started.elapsed();
    let mut latencies = Arc::into_inner(latencies).unwrap().into_inner().unwrap();
    latencies.sort_unstable();
    let duration_s = elapsed.as_secs_f64();
    Ok(BenchmarkReport {
        device_identity: identity,
        layer: layer.to_string(),
        filesystem,
        mode: if write { "write" } else { "read" }.to_string(),
        bytes,
        block_size,
        queue_depth,
        duration_ms: elapsed.as_millis() as u64,
        throughput_bytes_s: (bytes as f64 / duration_s) as u64,
        iops: blocks as f64 / duration_s,
        latency_p50_us: percentile(&latencies, 50),
        latency_p95_us: percentile(&latencies, 95),
        latency_p99_us: percentile(&latencies, 99),
        cpu_seconds: (cpu_seconds() - cpu_before).max(0.0),
        verified: !verify || !failed.load(Ordering::Relaxed),
    })
}

fn fill_pattern(block: u64, buffer: &mut [u8]) {
    let mut state = block ^ 0x9E37_79B9_7F4A_7C15;
    for chunk in buffer.chunks_mut(8) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let bytes = state.to_le_bytes();
        chunk.copy_from_slice(&bytes[..chunk.len()]);
    }
}

fn percentile(values: &[u64], percentile: usize) -> u64 {
    if values.is_empty() {
        return 0;
    }
    values[((values.len() - 1) * percentile / 100).min(values.len() - 1)]
}

fn cpu_seconds() -> f64 {
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } != 0 {
        return 0.0;
    }
    let time = |value: libc::timeval| value.tv_sec as f64 + value.tv_usec as f64 / 1_000_000.0;
    time(usage.ru_utime) + time(usage.ru_stime)
}

fn sm4_benchmark(mib: u64, iterations: u32, json: bool) -> Result<()> {
    if mib == 0 || iterations == 0 {
        bail!("mib 和 iterations 必须大于 0");
    }
    let bytes = mib.checked_mul(1024 * 1024).context("测试大小过大")?;
    let original = vec![0x5au8; bytes as usize];
    let cipher = edp_core::sm4_ecb::Sm4Ecb::new(&[0x42; 16]);
    let mut reports = Vec::new();
    let mut buffer = original.clone();
    for (mode, encrypt) in [("encrypt", true), ("decrypt", false)] {
        let started = Instant::now();
        for _ in 0..iterations {
            if encrypt {
                cipher.encrypt_aligned_in_place(&mut buffer)?;
            } else {
                cipher.decrypt_aligned_in_place(&mut buffer)?;
            }
        }
        let elapsed = started.elapsed();
        let total = bytes * iterations as u64;
        reports.push(BenchmarkReport {
            device_identity: "cpu".into(),
            layer: "sm4".into(),
            filesystem: None,
            mode: mode.into(),
            bytes: total,
            block_size: 16,
            queue_depth: 1,
            duration_ms: elapsed.as_millis() as u64,
            throughput_bytes_s: (total as f64 / elapsed.as_secs_f64()) as u64,
            iops: total as f64 / 16.0 / elapsed.as_secs_f64(),
            latency_p50_us: 0,
            latency_p95_us: 0,
            latency_p99_us: 0,
            cpu_seconds: elapsed.as_secs_f64(),
            verified: true,
        });
    }
    if buffer != original {
        bail!("SM4 加解密闭环校验失败");
    }
    print_reports(&reports, json)
}

fn print_reports(reports: &[BenchmarkReport], json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(reports)?);
    } else {
        for report in reports {
            println!(
                "{} {}: {:.1} MB/s, {:.0} IOPS, P95={}us, QD={}, verified={}",
                report.layer,
                report.mode,
                report.throughput_bytes_s as f64 / 1_000_000.0,
                report.iops,
                report.latency_p95_us,
                report.queue_depth,
                report.verified
            );
        }
    }
    Ok(())
}

struct DeviceIdentity {
    bsd: String,
    size: u64,
}

fn locate_hiksemi(serial: &str, vendor: &str, product: &str) -> Result<DeviceIdentity> {
    let output = std::process::Command::new("/usr/sbin/system_profiler")
        .args(["SPUSBDataType", "-json"])
        .output()?;
    if !output.status.success() {
        bail!("system_profiler USB 枚举失败");
    }
    let root: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    find_identity(&root, serial, vendor, product).context("未找到三重身份匹配的 HIKSEMI")
}

fn find_identity(
    value: &serde_json::Value,
    serial: &str,
    vendor: &str,
    product: &str,
) -> Option<DeviceIdentity> {
    match value {
        serde_json::Value::Object(object) => {
            let matches = object.get("serial_num").and_then(|v| v.as_str()) == Some(serial)
                && object
                    .get("vendor_id")
                    .and_then(|v| v.as_str())
                    .is_some_and(|value| {
                        value
                            .to_ascii_lowercase()
                            .starts_with(&vendor.to_ascii_lowercase())
                    })
                && object
                    .get("product_id")
                    .and_then(|v| v.as_str())
                    .is_some_and(|value| value.eq_ignore_ascii_case(product));
            if matches {
                return find_media(value);
            }
            object
                .values()
                .find_map(|value| find_identity(value, serial, vendor, product))
        }
        serde_json::Value::Array(array) => array
            .iter()
            .find_map(|value| find_identity(value, serial, vendor, product)),
        _ => None,
    }
}

fn find_media(value: &serde_json::Value) -> Option<DeviceIdentity> {
    match value {
        serde_json::Value::Object(object) => {
            if let (Some(bsd), Some(size)) = (
                object.get("bsd_name").and_then(|value| value.as_str()),
                object.get("size_in_bytes").and_then(|value| value.as_u64()),
            ) {
                if bsd.strip_prefix("disk").is_some_and(|suffix| {
                    !suffix.is_empty() && suffix.chars().all(|ch| ch.is_ascii_digit())
                }) {
                    return Some(DeviceIdentity {
                        bsd: bsd.to_string(),
                        size,
                    });
                }
            }
            object.values().find_map(find_media)
        }
        serde_json::Value::Array(array) => array.iter().find_map(find_media),
        _ => None,
    }
}

fn validate_external_physical(bsd: &str) -> Result<()> {
    if !bsd.starts_with("disk") || bsd.chars().skip(4).any(|ch| !ch.is_ascii_digit()) {
        bail!("非法 BSD 设备名: {bsd}");
    }
    let output = std::process::Command::new("/usr/sbin/diskutil")
        .args(["list", "external", "physical"])
        .output()?;
    let listing = String::from_utf8_lossy(&output.stdout);
    if !listing.contains(&format!("/dev/{bsd} (external, physical)")) {
        bail!("{bsd} 不是当前的外置物理盘");
    }
    Ok(())
}
