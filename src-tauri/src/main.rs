// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

// CLI 子命令模式(GUI 之外): edpopen --analyze <diskN>
// (后续 --write-sectors 提权写入器同此入口)
fn main() {
    let args: Vec<String> = std::env::args().collect();
    // 提权写入器: 由 osascript 以 root 拉起(见 commands::apply_convert)
    if args.len() >= 3 && args[1] == "--write-sectors" {
        let payload = std::path::PathBuf::from(&args[2]);
        let result = payload.with_extension("result.json");
        let code = edpopen_lib::convert::write_sectors_run(&payload, &result);
        eprintln!("result: {}", result.display());
        std::process::exit(code);
    }
    if args.len() >= 3 && args[1] == "--analyze" {
        let disk: u32 = args[2].parse().unwrap_or_else(|_| {
            eprintln!("错误: 盘号须为数字, 如 --analyze 4");
            std::process::exit(2);
        });
        match edpopen_lib::commands::analyze_disk(disk) {
            Ok(o) => println!("{}", serde_json::to_string_pretty(&o).unwrap()),
            Err(e) => { eprintln!("错误: {e}"); std::process::exit(1); }
        }
        return;
    }
    edpopen_lib::run()
}
