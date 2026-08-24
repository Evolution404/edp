//! macOS 工作线程服务质量设置。

/// 将当前线程标记为用户发起的 I/O 工作。
///
/// SMAppService 的 daemon 子进程默认会继承较低的线程 QoS。加密桥直接位于
/// Finder 文件 I/O 的同步路径上，因此只提升实际处理请求的线程；空闲 daemon
/// 主线程仍保持系统默认优先级。
#[cfg(target_os = "macos")]
pub fn set_current_thread_user_initiated() {
    const QOS_CLASS_USER_INITIATED: u32 = 0x19;
    unsafe extern "C" {
        fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: i32) -> i32;
    }
    // 失败只影响性能，不应导致挂载失败。
    let _ = unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) };
}

#[cfg(not(target_os = "macos"))]
pub fn set_current_thread_user_initiated() {}
