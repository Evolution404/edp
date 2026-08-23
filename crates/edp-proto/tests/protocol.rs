//! 协议测试：server + client + 事件广播。

use std::collections::HashMap;
use std::sync::Arc;

use edp_proto::{serve, types, Client};
use serde_json::json;

struct StubState {
    pub calls: std::sync::atomic::AtomicU32,
}

fn start_server() -> (String, edp_proto::ServerHandle) {
    use std::sync::atomic::{AtomicU32, Ordering};
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let n = COUNTER.fetch_add(1, Ordering::SeqCst);
    let path = format!("/tmp/edp-proto-test-{}-{}.sock", std::process::id(), n);
    let state = Arc::new(StubState {
        calls: std::sync::atomic::AtomicU32::new(0),
    });
    fn handler<F>(f: F) -> edp_proto::Handler
    where
        F: Fn(
                &edp_proto::Context,
                serde_json::Value,
            ) -> Result<serde_json::Value, edp_proto::RpcError>
            + Send
            + Sync
            + 'static,
    {
        Arc::new(f)
    }

    let methods: HashMap<String, edp_proto::Handler> = [
        (
            types::method::STATUS.to_string(),
            handler(|ctx: &edp_proto::Context, _p: serde_json::Value| {
                let s = ctx.state::<StubState>().unwrap();
                s.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(json!({"peer_uid": ctx.peer_uid, "version": "0.2.0"}))
            }),
        ),
        (
            "echo".to_string(),
            handler(|_ctx: &edp_proto::Context, p: serde_json::Value| Ok(p)),
        ),
        (
            types::method::SUBSCRIBE.to_string(),
            handler(|_ctx: &edp_proto::Context, _p: serde_json::Value| Ok(json!({"ok": true}))),
        ),
    ]
    .into_iter()
    .collect();
    let handle = serve(&path, methods, vec![501], state).unwrap();
    (path, handle)
}

#[test]
fn call_and_response() {
    let (path, mut handle) = start_server();
    let mut c = Client::connect(&path).unwrap();
    let r = c.call(types::method::STATUS, json!({})).unwrap();
    assert_eq!(r["version"], "0.2.0");
    // 对端 uid 应是本进程 uid（501）
    assert!(r["peer_uid"].as_u64().is_some());
    handle.shutdown();
}

#[test]
fn echo_roundtrip() {
    let (path, mut handle) = start_server();
    let mut c = Client::connect(&path).unwrap();
    let payload = json!({"a": [1, 2, 3], "b": "hello"});
    let r = c.call("echo", payload.clone()).unwrap();
    assert_eq!(r, payload);
    handle.shutdown();
}

#[test]
fn unknown_method_rejected() {
    let (path, mut handle) = start_server();
    let mut c = Client::connect(&path).unwrap();
    let e = c.call("no_such_method", json!({})).unwrap_err();
    match e {
        edp_proto::ClientError::Rpc(code, _) => {
            assert_eq!(code, types::codes::METHOD_NOT_FOUND)
        }
        other => panic!("应返回 Rpc 错误，实际 {other:?}"),
    }
    handle.shutdown();
}

#[test]
fn event_broadcast() {
    let (path, mut handle) = start_server();
    let broadcaster = handle.broadcaster.clone();
    let mut c = Client::connect(&path).unwrap();
    // 先 subscribe
    c.call(types::method::SUBSCRIBE, json!({})).unwrap();
    // 再广播
    std::thread::sleep(std::time::Duration::from_millis(200));
    broadcaster.broadcast(types::event::MOUNTED, json!({"session_id": "x"}));
    // 订阅线程读取
    std::thread::sleep(std::time::Duration::from_millis(300));
    handle.shutdown();
}

#[test]
fn subscribe_receives_events() {
    let (path, mut handle) = start_server();
    let broadcaster = handle.broadcaster.clone();
    let mut c = Client::connect(&path).unwrap();
    let (tx, rx) = std::sync::mpsc::channel::<edp_proto::types::Event>();
    std::thread::spawn(move || {
        // 阻塞订阅，直到连接断开（进程退出时自然结束，不做 join）
        let _ = c.subscribe(move |ev| {
            let _ = tx.send(ev);
        });
    });
    // 等服务端注册订阅
    std::thread::sleep(std::time::Duration::from_millis(300));
    broadcaster.broadcast(
        types::event::MOUNTED,
        json!({"session_id": "s1", "mountpoint": "/Volumes/EDP"}),
    );
    broadcaster.broadcast(types::event::UNMOUNTED, json!({"session_id": "s1"}));
    let ev1 = rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
    let ev2 = rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
    assert_eq!(ev1.event, types::event::MOUNTED);
    assert_eq!(ev2.event, types::event::UNMOUNTED);
    assert_eq!(ev1.data["session_id"], "s1");
    handle.shutdown();
}
