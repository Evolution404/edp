//! UDS socket 客户端。

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

use crate::types::{Request, Response};
use serde_json::Value;

/// RPC 客户端（CLI / GUI 共用）。
pub struct Client {
    stream: UnixStream,
    next_id: u64,
}

impl Client {
    /// 连接 UDS。失败即视为 daemon 不在线（调用方据此走离线模式）。
    pub fn connect(path: &str) -> std::io::Result<Self> {
        let stream = UnixStream::connect(path)?;
        stream.set_read_timeout(Some(std::time::Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(std::time::Duration::from_secs(10)))?;
        Ok(Client { stream, next_id: 1 })
    }

    /// 调整后续 RPC 的读超时。长时间诊断任务可显式延长或取消超时，
    /// 普通 GUI/CLI 请求仍保留默认 30 秒上限。
    pub fn set_read_timeout(&self, timeout: Option<std::time::Duration>) -> std::io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    /// 发起一次请求，等待响应。
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, ClientError> {
        let id = self.next_id;
        self.next_id += 1;
        let req = Request {
            id,
            method: method.to_string(),
            params,
        };
        let mut line = serde_json::to_string(&req)?;
        line.push('\n');
        self.stream.write_all(line.as_bytes())?;
        self.stream.flush()?;

        let mut reader = BufReader::new(&mut self.stream);
        let mut buf = String::new();
        reader.read_line(&mut buf)?;
        let resp: Response = serde_json::from_str(&buf)?;
        if resp.id != id {
            return Err(ClientError::Protocol(format!(
                "响应 id 不匹配: expect {id} got {}",
                resp.id
            )));
        }
        if !resp.ok {
            let e = resp.error.unwrap_or_else(|| crate::types::RpcError {
                code: "UNKNOWN".into(),
                message: "未知错误".into(),
            });
            return Err(ClientError::Rpc(e.code, e.message));
        }
        resp.result
            .ok_or_else(|| ClientError::Protocol("成功响应缺少 result".into()))
    }

    /// 订阅事件并阻塞读取，逐条回调（GUI 侧专用线程）。
    ///
    /// 内部自己写 SUBSCRIBE 请求并直接读行（不复用 `call`，避免 BufReader
    /// 缓冲导致事件帧丢失）。连接断开或服务端下线时返回。
    pub fn subscribe<F>(&mut self, mut on_event: F) -> Result<(), ClientError>
    where
        F: FnMut(crate::types::Event),
    {
        // A subscription is intentionally idle between disk events. The normal
        // 30-second RPC timeout would silently tear it down and create a window
        // in which insert/remove events can be lost.
        self.stream.set_read_timeout(None)?;
        let id = self.next_id;
        self.next_id += 1;
        let req = Request {
            id,
            method: crate::types::method::SUBSCRIBE.to_string(),
            params: serde_json::json!({}),
        };
        let mut line = serde_json::to_string(&req)?;
        line.push('\n');
        self.stream.write_all(line.as_bytes())?;
        self.stream.flush()?;

        let mut reader = BufReader::new(&mut self.stream);
        let mut buf = String::new();
        buf.clear();
        reader.read_line(&mut buf)?;
        let resp: Response = serde_json::from_str(&buf)?;
        if !resp.ok {
            let e = resp.error.unwrap_or_else(|| crate::types::RpcError {
                code: "UNKNOWN".into(),
                message: "未知错误".into(),
            });
            return Err(ClientError::Rpc(e.code, e.message));
        }
        loop {
            buf.clear();
            if reader.read_line(&mut buf)? == 0 {
                break;
            }
            let line = buf.trim();
            if line.is_empty() {
                continue;
            }
            if let Ok(ev) = serde_json::from_str::<crate::types::Event>(line) {
                on_event(ev);
            }
        }
        Ok(())
    }
}

/// 客户端错误。
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("RPC 错误[{0}]: {1}")]
    Rpc(String, String),
    #[error("协议错误: {0}")]
    Protocol(String),
    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON 错误: {0}")]
    Json(#[from] serde_json::Error),
}
