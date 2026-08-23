# usbcore UDS JSON-RPC 协议

> 状态：M0 骨架，M2 实现时细化。

## 传输

- Unix domain socket：`/var/run/edp-usbcore.sock`（0660 root:admin）
- NDJSON：每行一个 JSON 对象，UTF-8
- 鉴权：`LOCAL_PEERCRED` 取对端 uid（root / admin 白名单 / config.allowed_uids）

## 帧

```json
{"id": 1, "method": "mount", "params": {"disk": "disk4"}}
{"id": 1, "ok": true, "result": {"session_id": "edp-disk4-ab12cd34", "mountpoint": "/Volumes/EDP"}}
{"id": 1, "ok": false, "error": {"code": "PASSWORD_MISMATCH", "message": "密码错误"}}
{"event": "mounted", "data": {"session_id": "...", "mountpoint": "..."}}
```

## 方法集（M2）

`status` / `list_disks` / `probe` / `mount` / `unmount` / `sessions` /
`keys.ls` / `keys.add` / `keys.rm` / `keys.update` /
`config.get` / `config.set` / `logs.read` / `subscribe` / `unsubscribe` / `daemon.shutdown`

## 事件

`disk_appeared` / `mounted` / `mount_failed` / `password_needed` / `unmounted` / `disk_removed`
