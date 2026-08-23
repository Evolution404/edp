//! UDS JSON-RPC 服务端框架。
//!
//! - 监听 UDS（0660 root:admin）
//! - 连接建立后 `LOCAL_PEERCRED` 取对端 uid，按白名单鉴权
//! - NDJSON 请求/响应；subscribe 后事件经每连接 channel 推送
//! - 每连接一线程；订阅后另起事件推送线程（共用写锁，防响应/事件交错）

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::Value;

use crate::types::{Event, Request, Response, RpcError};

/// 方法处理函数。
pub type Handler = Arc<dyn Fn(&Context, Value) -> Result<Value, RpcError> + Send + Sync>;

/// RPC 上下文。
pub struct Context {
    /// 对端 uid。
    pub peer_uid: u32,
    /// 全局状态（daemon 注入）。
    pub state: Arc<dyn std::any::Any + Send + Sync>,
    /// 事件广播器。
    pub broadcaster: EventBroadcaster,
}

impl Context {
    /// 取 daemon 注入的状态。
    pub fn state<T: Send + Sync + 'static>(&self) -> Option<&T> {
        self.state.downcast_ref::<T>()
    }

    /// 对端是否为 root。
    pub fn is_root(&self) -> bool {
        self.peer_uid == 0
    }
}

/// 事件广播器。
#[derive(Clone)]
pub struct EventBroadcaster {
    subs: Arc<Mutex<HashMap<usize, std::sync::mpsc::Sender<Event>>>>,
    next_id: Arc<std::sync::atomic::AtomicUsize>,
}

impl Default for EventBroadcaster {
    fn default() -> Self {
        Self {
            subs: Arc::new(Mutex::new(HashMap::new())),
            next_id: Arc::new(std::sync::atomic::AtomicUsize::new(1)),
        }
    }
}

impl EventBroadcaster {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn broadcast(&self, event: &str, data: Value) {
        let subs = self.subs.lock().unwrap();
        for tx in subs.values() {
            let _ = tx.send(Event {
                event: event.to_string(),
                data: data.clone(),
            });
        }
    }

    fn register(&self) -> (usize, std::sync::mpsc::Receiver<Event>) {
        let id = self
            .next_id
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let (tx, rx) = std::sync::mpsc::channel();
        self.subs.lock().unwrap().insert(id, tx);
        (id, rx)
    }

    fn unregister(&self, id: usize) {
        self.subs.lock().unwrap().remove(&id);
    }
}

/// 服务端句柄。
pub struct ServerHandle {
    pub socket_path: String,
    pub broadcaster: EventBroadcaster,
    /// listener 线程句柄（detach，不 join——accept 会永久阻塞）。
    #[allow(dead_code)]
    join: Option<thread::JoinHandle<()>>,
}

impl ServerHandle {
    /// 停止服务：删除 socket 文件（listener 线程随之结束 accept 循环，
    /// 已建立连接自然关闭）。
    pub fn shutdown(&mut self) {
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// 启动服务。
pub fn serve(
    socket_path: &str,
    methods: HashMap<String, Handler>,
    allowed_uids: Vec<u32>,
    state: Arc<dyn std::any::Any + Send + Sync>,
) -> std::io::Result<ServerHandle> {
    let _ = std::fs::remove_file(socket_path);
    let listener = UnixListener::bind(socket_path)?;
    std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o660))?;
    // chown 到 root:admin：daemon（launchd root:daemon）创建的 socket 组默认为
    // daemon，控制台用户不在 daemon 组会无法连接。admin 组放行控制台用户
    // （GUI/CLI 免 sudo 走 RPC 的前提），具体授权仍由 LOCAL_PEERCRED 白名单决定。
    #[cfg(unix)]
    unsafe {
        use std::ffi::CString;
        let gname = CString::new("admin").unwrap();
        let gr = libc::getgrnam(gname.as_ptr());
        if !gr.is_null() {
            let gid = (*gr).gr_gid;
            let path = CString::new(socket_path).unwrap();
            // 非 root 下 chown 会 EPERM，忽略（测试用临时 socket 由属主直接连接）
            libc::chown(path.as_ptr(), 0, gid);
        }
    }

    let broadcaster = EventBroadcaster::new();
    let broadcaster_loop = broadcaster.clone();
    let join = thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(stream) = conn else { continue };
            let methods = methods.clone();
            let broadcaster = broadcaster_loop.clone();
            let state = state.clone();
            let allowed = allowed_uids.clone();
            thread::spawn(move || {
                let _ = handle_conn(stream, methods, broadcaster, allowed, state);
            });
        }
    });
    Ok(ServerHandle {
        socket_path: socket_path.to_string(),
        broadcaster,
        join: Some(join),
    })
}

/// 对端 uid（LOCAL_PEERCRED）。
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    use std::os::unix::io::AsRawFd;
    #[repr(C)]
    struct XUcred {
        pub version: u32,
        pub euid: u32,
        pub egid: u32,
        pub ngroups: u16,
        pub groups: [u32; 1],
    }
    let mut cred: XUcred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<XUcred>() as u32;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERCRED,
            &mut cred as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if rc == 0 {
        Some(cred.euid)
    } else {
        None
    }
}

fn is_allowed(uid: u32, allowed: &[u32]) -> bool {
    uid == 0 || allowed.contains(&uid)
}

fn handle_conn(
    stream: UnixStream,
    methods: HashMap<String, Handler>,
    broadcaster: EventBroadcaster,
    allowed: Vec<u32>,
    state: Arc<dyn std::any::Any + Send + Sync>,
) -> std::io::Result<()> {
    let uid = peer_uid(&stream).unwrap_or(u32::MAX);
    let authorized = is_allowed(uid, &allowed);
    let ctx = Context {
        peer_uid: uid,
        state,
        broadcaster: broadcaster.clone(),
    };

    // 读/写分流：主线程读请求、写响应；事件推送线程写事件——共用写锁防交错
    let writer = std::sync::Arc::new(std::sync::Mutex::new(stream.try_clone()?));
    let mut reader = BufReader::new(stream);
    // 当前订阅注册 id（用于注销；事件 receiver 已在推送线程内）
    let mut sub: Option<usize> = None;

    let write_resp = |resp: &Response| -> std::io::Result<()> {
        let mut l = serde_json::to_string(resp)?;
        l.push('\n');
        let mut w = writer.lock().unwrap();
        w.write_all(l.as_bytes())?;
        w.flush()
    };

    let mut buf = String::new();
    loop {
        buf.clear();
        if reader.read_line(&mut buf)? == 0 {
            break;
        }
        let line = buf.trim();
        if line.is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(_) => {
                let resp = Response {
                    id: 0,
                    ok: false,
                    result: None,
                    error: Some(RpcError::new(crate::types::codes::BAD_PARAMS, "非法 JSON")),
                };
                write_resp(&resp)?;
                continue;
            }
        };

        // 鉴权：未授权仅放行 status（用于 daemon 状态探测）
        let resp = if !authorized && req.method != crate::types::method::STATUS {
            Response {
                id: req.id,
                ok: false,
                result: None,
                error: Some(RpcError::new(
                    crate::types::codes::PERMISSION_DENIED,
                    "无权限：连接者不在允许列表（需 root 或 daemon 授权用户）",
                )),
            }
        } else if let Some(h) = methods.get(&req.method) {
            match h(&ctx, req.params.clone()) {
                Ok(result) => Response {
                    id: req.id,
                    ok: true,
                    result: Some(result),
                    error: None,
                },
                Err(e) => Response {
                    id: req.id,
                    ok: false,
                    result: None,
                    error: Some(e),
                },
            }
        } else {
            Response {
                id: req.id,
                ok: false,
                result: None,
                error: Some(RpcError::new(
                    crate::types::codes::METHOD_NOT_FOUND,
                    format!("未知方法: {}", req.method),
                )),
            }
        };
        write_resp(&resp)?;

        // subscribe：注册事件接收，启动专用推送线程（阻塞 recv，注销时 channel
        // 断开自动退出）
        if req.method == crate::types::method::SUBSCRIBE && resp.ok {
            let (id, rx) = broadcaster.register();
            let w = writer.clone();
            std::thread::spawn(move || {
                while let Ok(ev) = rx.recv() {
                    let mut l = serde_json::to_string(&ev).unwrap_or_default();
                    l.push('\n');
                    if let Ok(mut w) = w.lock() {
                        let _ = w.write_all(l.as_bytes());
                        let _ = w.flush();
                    }
                }
            });
            sub = Some(id);
        }
        if req.method == crate::types::method::UNSUBSCRIBE {
            if let Some(id) = sub.take() {
                broadcaster.unregister(id);
            }
        }
    }
    if let Some(id) = sub.take() {
        broadcaster.unregister(id);
    }
    Ok(())
}
