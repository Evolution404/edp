//! # edp-proto
//!
//! usbcore 的 UDS JSON-RPC 协议库（M2 填充）：
//! - 请求/响应/事件帧类型（NDJSON，每行一个 JSON 对象）
//! - `Client`：CLI 与 GUI 共用的 socket 客户端
//! - `Server`：daemon 侧的连接处理框架（LOCAL_PEERCRED 鉴权）
