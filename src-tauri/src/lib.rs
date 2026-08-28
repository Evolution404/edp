pub mod crypto;
pub mod parser;
pub mod disk;
pub mod convert;
pub mod commands;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::ping,
            commands::list_disks,
            commands::analyze_disk
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
