use serde::Serialize;

#[derive(Serialize)]
pub struct DiskInfo {
    pub disk: u32,
    pub size_bytes: u64,
    pub vid: String,
    pub pid: String,
}

#[tauri::command]
pub fn ping() -> String {
    "edpopen-backend-ready".into()
}

/// 占位: 盘枚举(disk.rs 完成后实现)
#[tauri::command]
pub fn list_disks() -> Vec<DiskInfo> {
    Vec::new()
}
