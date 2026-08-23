# 架构

> 状态：M0 骨架，随里程碑更新。

## 进程模型

单一多角色二进制 `usbcore`：

| 角色 | 入口 | 职责 |
|---|---|---|
| CLI | `usbcore <cmd>` | 终端操作；daemon 在线走 socket 免 sudo，离线 sudo 直跑 |
| daemon | `usbcore daemon run` | launchd 常驻（root）：磁盘监听、密码库、自动挂载、RPC server |
| bridge | `usbcore bridge` | macFUSE 单文件桥（daemon/CLI spawn，file_key 走匿名管道） |
| GUI | `EDP USB Client.app` | Tauri 2 菜单栏应用，纯 RPC 客户端 |

## 模块划分

```
crates/
├── edp-core/     纯算法与格式层（跨平台，零系统依赖）
├── edp-macos/    macOS 系统集成（diskutil/ioreg/hdiutil/DiskArbitration）
├── edp-proto/    UDS JSON-RPC 协议（Client/Server）
└── usbcore/      多角色二进制（cli + daemon + bridge）
gui/              Tauri 2 + Vue 3（M3）
```

## 挂载数据流

```
插入 → DiskArbitration appeared → 预筛（LBA4 "$$"）
  → device_id 三级发现（explicit → LBA11 PDKB → identify 候选）
  → 密码库按 (device_id, partition_type) 取多条 → 密码双路径验证
  → diskutil unmountDisk → spawn bridge（匿名管道传 file_key）
  → hdiutil attach -nobrowse -owners off -imagekey diskimage-class=CRawDiskImage
  → 原生 exFAT 驱动 → /Volumes/...
```

## 密钥生命周期与安全模型

- 密码仅作认证因子；数据主密钥 `file_key` 每次从 LBA12 重新派生
- `file_key` 只经匿名管道传给 bridge，永不进 argv/env/磁盘/日志/会话文件
- 密码库：`/var/db/edp-usbcore/store.enc`（AES-256-GCM，KEK 随机文件 0600 root-only）
- 威胁模型：防同机非 root 进程；root 攻击者可读 daemon 内存，任何方案（含 Keychain）不可防
