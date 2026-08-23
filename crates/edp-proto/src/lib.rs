//! # edp-proto
//!
//! usbcore 的 UDS JSON-RPC 协议库。
//! - NDJSON：每行一个 JSON 对象（UTF-8）
//! - 请求 `{"id", "method", "params"}` / 响应 `{"id", "ok", "result"|"error"}`
//! - 事件（subscribe 后推送）`{"event", "data"}`
//!
//! ## 鉴权
//! socket 0660 root:admin；连接建立后服务端用 `LOCAL_PEERCRED` 取对端 uid，
//! 允许 root / admin 组成员（或 config.allowed_uids）。

pub mod client;
pub mod server;
pub mod types;

pub use client::{Client, ClientError};
pub use server::{serve, Context, EventBroadcaster, Handler, ServerHandle};
pub use types::*;
