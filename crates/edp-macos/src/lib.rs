//! # edp-macos
//!
//! macOS 系统集成层（M1/M2 填充）：
//! - `diskutil`/`ioreg`/`hdiutil` 子进程封装（plist 解析）
//! - DiskArbitration 磁盘事件监听（objc2 绑定）
//! - macFUSE 检测

#![cfg(target_os = "macos")]
