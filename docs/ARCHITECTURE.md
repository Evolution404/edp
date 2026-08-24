# 架构

> 状态：M3（Tauri GUI 已接入）。GUI 独立 cargo workspace，经 UDS socket 纯 RPC 访问 daemon。

## 进程模型

单一多角色二进制 `usbcore` + 独立 Tauri GUI：

| 角色 | 入口 | 职责 |
|---|---|---|
| CLI | `usbcore <cmd>` | 终端操作；daemon 在线走 socket 免 sudo，离线 sudo 直跑 |
| daemon | `usbcore daemon run` | launchd 常驻（root）：磁盘监听、密码库、自动挂载、RPC server |
| bridge | `usbcore bridge` | macFUSE 单文件桥（daemon/CLI spawn，file_key 走匿名管道） |
| GUI | `EDP USB Client.app` | Tauri 2 菜单栏应用（accessory，无 Dock），纯 RPC 客户端 |

## 模块划分

```
crates/
├── edp-core/     纯算法与格式层（跨平台，零系统依赖）
├── edp-macos/    macOS 系统集成（diskutil/ioreg/hdiutil/DiskArbitration）
├── edp-proto/    UDS JSON-RPC 协议（Client/Server，含事件订阅流）
└── usbcore/      多角色二进制（cli + daemon + bridge）
gui/
├── src/          Vue 3 + Pinia + Vue Router（Keys/Sessions/Settings/Logs 四页）
└── src-tauri/    独立 workspace：RPC 命令 + 托盘 + 事件订阅 + 通知 + daemon 安装
```

## GUI ↔ daemon

- 所有数据走 UDS JSON-RPC（`edp-proto`），**GUI 不直接读盘、不接触密码库文件**
- `subscribe` 长连接实时接收 `mounted/unmounted/disk_appeared/…` → 前端事件 + 系统通知 + 托盘菜单重建
- daemon 离线时 GUI 显示引导（设置页可提权安装 daemon、macFUSE 引导）
- 唯一提权动作：`install_daemon` 经 `osascript … with administrator privileges` 执行 `usbcore daemon install`

## 挂载数据流

```
插入 → 磁盘 appeared → 只读恢复并校验 LBA7 EDPF 结构
  → device_id 三级发现（explicit → LBA11 PDKB → identify 候选）
  → 检查全局运行状态 + 逐盘授权 + 逐分区选择
  → 密码库按 (device_id, partition_type) 取多条 → 只读密码/文件系统闭环
  → 形成至少一个有效计划后才 diskutil unmountDisk（每盘一次）
  → spawn bridge（匿名管道传 file_key）
  → hdiutil attach -nobrowse -owners off -imagekey diskimage-class=CRawDiskImage
  → 原生 exFAT 驱动 → /Volumes/...
```

普通盘、未授权盘、密码缺失或验证失败的盘不会进入 `unmountDisk`。全局开关只暂停新的自动挂载，
不修改逐盘授权，也不卸载现有会话；恢复后重新评估当前已插入设备。

同一物理盘可拥有多个活动 session（交换区/保密区）。daemon 同时维护 session 索引和物理盘到
session 集合的反向索引，拔盘、手动卸载与安全停止均据此完整清理。

## 密钥生命周期与安全模型

- 密码仅作认证因子；数据主密钥 `file_key` 每次从 LBA12 重新派生
- `file_key` 只经匿名管道传给 bridge，永不进 argv/env/磁盘/日志/会话文件
- 密码库：`/var/db/edp-usbcore/store.enc`（AES-256-GCM，KEK 随机文件 0600 root-only）
- 威胁模型：防同机非 root 进程；root 攻击者可读 daemon 内存，任何方案（含 Keychain）不可防
