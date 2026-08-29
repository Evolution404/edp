pub mod crypto;
pub mod parser;
pub mod disk;
pub mod convert;
pub mod editor;
pub mod commands;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::ping,
            commands::list_disks,
            commands::analyze_disk,
            commands::read_sector,
            commands::disk_map,
            commands::convert_preview,
            commands::apply_convert,
            commands::list_backups,
            commands::restore_backup,
            commands::preview_sector_edit,
            commands::apply_sector_edit
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
