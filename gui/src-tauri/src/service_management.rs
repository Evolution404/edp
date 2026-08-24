//! Thin, typed wrapper around macOS Service Management.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    NotRegistered,
    Enabled,
    RequiresApproval,
    NotFound,
}

#[cfg(target_os = "macos")]
mod platform {
    use super::Status;
    use std::ffi::{c_char, CStr};
    use std::process::{Command, Stdio};

    const LEGACY_LABEL: &str = "system/com.edp.usbvault.daemon.v2";

    unsafe extern "C" {
        fn edp_sm_service_status() -> i32;
        fn edp_sm_service_register(buffer: *mut c_char, length: usize) -> bool;
        fn edp_sm_service_unregister(buffer: *mut c_char, length: usize) -> bool;
        fn edp_sm_open_login_items();
    }

    fn operation(call: unsafe extern "C" fn(*mut c_char, usize) -> bool) -> Result<(), String> {
        let mut buffer = [0_i8; 1024];
        if unsafe { call(buffer.as_mut_ptr(), buffer.len()) } {
            return Ok(());
        }
        let message = unsafe { CStr::from_ptr(buffer.as_ptr()) }
            .to_string_lossy()
            .trim()
            .to_string();
        Err(if message.is_empty() {
            "Service Management 操作失败".to_string()
        } else {
            message
        })
    }

    fn installer_daemon_enabled() -> bool {
        Command::new("/bin/launchctl")
            .args(["print", LEGACY_LABEL])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    pub fn status() -> Status {
        match unsafe { edp_sm_service_status() } {
            1 => Status::Enabled,
            2 => Status::RequiresApproval,
            0 if installer_daemon_enabled() => Status::Enabled,
            0 => Status::NotRegistered,
            _ if installer_daemon_enabled() => Status::Enabled,
            _ => Status::NotFound,
        }
    }

    pub fn register() -> Result<(), String> {
        if installer_daemon_enabled() {
            return Ok(());
        }
        operation(edp_sm_service_register)
    }

    pub fn unregister() -> Result<(), String> {
        if installer_daemon_enabled() {
            return Err(
                "当前后台服务由一体化安装器管理。测试版请使用卸载/清理命令移除后台服务。"
                    .to_string(),
            );
        }
        operation(edp_sm_service_unregister)
    }

    pub fn open_login_items() {
        unsafe { edp_sm_open_login_items() };
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::Status;

    pub fn status() -> Status {
        Status::NotFound
    }
    pub fn register() -> Result<(), String> {
        Err("嵌入式后台服务仅支持 macOS".to_string())
    }
    pub fn unregister() -> Result<(), String> {
        Err("嵌入式后台服务仅支持 macOS".to_string())
    }
    pub fn open_login_items() {}
}

pub use platform::*;
