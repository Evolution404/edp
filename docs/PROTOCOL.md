# usbcore UDS JSON-RPC 协议

> 状态：M2 已实现（daemon + CLI 在线模式 + 集成测试）。GUI（M3）与 CLI 均经此协议调用 daemon。

## 传输

- Unix domain socket：默认 `/var/run/com.edp.usbvault.daemon.sock`（测试可用 `--socket` / `EDP_USB_SOCKET` 覆盖），0660
- NDJSON：每行一个 JSON 对象，UTF-8；`\n` 为帧分隔符
- 鉴权：连接建立后 `LOCAL_PEERCRED`（`getsockopt(SOL_LOCAL, LOCAL_PEERCRED)`）取对端 uid

## 鉴权与授权

- 放行规则：`uid == 0` 恒放行；否则须在 `allowed_uids` 白名单中
- `status` 方法对**未授权**连接也放行（用于在线探测），其余方法一律 `PERMISSION_DENIED`
- **白名单默认派生**（`Config.allowed_uids` 为空时，daemon 启动时自动填充）：
  - root 守护进程：`stat -f %u /dev/console` 取当前控制台登录用户（GUI/CLI 免 sudo 调用的前提）
  - 非 root（测试/开发）：daemon 自身 euid
- 嵌入式 root daemon 持久化到 `/var/db/com.edp.usbvault/config.json`；`config.set` 可覆盖

## 帧格式

```json
{"id": 1, "method": "mount", "params": {"disk": "disk4"}}
{"id": 1, "ok": true, "result": {"session_id": "edp-disk4-ab12cd34", "mountpoint": "/Volumes/EDP"}}
{"id": 1, "ok": false, "error": {"code": "INTERNAL", "message": "..."}}
{"event": "mounted", "data": {"session_id": "...", "mountpoint": "..."}}
```

## 方法

### `devices.list`

返回在线外置盘与已登记离线设备的合并视图，包括 `kind`、`device_id`、连接状态、凭据分区、
逐盘策略、已挂载分区和 session ids。`kind=ordinary` 的设备永远不可授权。

### `devices.policy.set`

以整份对象原子替换单盘策略：

```json
{
  "device_id": "disk&ven_lexar&prod_usb_flash_drive",
  "label": "工作盘",
  "authorized": true,
  "partition_types": [2, 4],
  "last_media_name": "Lexar USB Flash Drive Media"
}
```

### `auto_mount.get` / `auto_mount.set_mode`

全局自动挂载运行状态为 `active` 或 `paused`。暂停只阻止新自动挂载并保留逐盘授权和现有会话；
恢复为 `active` 后 daemon 立即重新评估当前设备。

| 方法 | 参数 | 结果 | 授权 |
|---|---|---|---|
| `status` | `{}` | `{version, uptime_s, macfuse, keystore_ok, keystore_entries, auto_mount_enabled, mounted_sessions}` | 匿名可读 |
| `list_disks` | `{all?}` | `[{bsd, rbsd, size, media_name, is_edp, ...}]` | 白名单 |
| `probe` | `{disk, partition_type?, password?}` | 探测报告 | 白名单 |
| `mount` | `{disk, partition_type?, readonly?, password?}` | 会话状态（含 `session_id`/`mountpoint`） | 白名单 |
| `unmount` | `{session_id, force?}` | `{unmounted}` | 白名单 |
| `sessions` | `{}` | `{sessions: [...]}` | 白名单 |
| `keys.ls` | `{}` | `[{id, label, device_id, partition_type, password_crc, password_hint, auto_mount, created_at, last_used_at}]`（**不含明文密码**） | 白名单 |
| `keys.add` | `{label?, device_id?, disk?, partition_type?, password, auto_mount?}` | `{id}` | 白名单 |
| `keys.rm` | `{id}` | `{removed}` | 白名单 |
| `keys.update` | `{id, label?, auto_mount?}` | `{ok}` | 白名单 |
| `config.get` / `config.set` | `{...}` | 配置 | 白名单 |
| `logs.read` | `{...}` | 日志尾部 | 白名单 |
| `subscribe` / `unsubscribe` | `{}` | `{ok: true}` | 白名单 |
| `daemon.shutdown` | `{exit?, purge_data?}` | `{ok, exit, purged}` | 已授权的本机控制端 |

> `keys.add` 的 device_id 解析：优先显式 `device_id`，否则 `disk` 现场 probe（`discover_volume`）后取命中 id。
> 密码经 socket 明文传输（本地 root socket + PEERCRED 鉴权；威胁模型见 ARCHITECTURE.md）。

## 事件（订阅后推送）

`disk_appeared` / `mounted` / `mount_failed` / `password_needed` / `unmounted` / `disk_removed`

## 错误码

`BAD_PARAMS` / `PERMISSION_DENIED` / `METHOD_NOT_FOUND` / `INTERNAL` / `PASSWORD_MISMATCH`

## CLI 在线优先策略

`usbcore mount/unmount/mounts/keys/*/status/doctor` 在 daemon 在线（socket 可连）时走 RPC 免 sudo；
离线时降级为本地执行（`mount` 需 sudo、`keys` 不可用、`status` 退出码 4）。
