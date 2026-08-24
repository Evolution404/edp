# EDP USB Vault — EDP 加密 U 盘 macOS 客户端

[![macOS App](https://github.com/Evolution404/edp-usb-vault/actions/workflows/macos-app.yml/badge.svg)](https://github.com/Evolution404/edp-usb-vault/actions/workflows/macos-app.yml)

VRV/CEMS **EDP 加密 U 盘**的 macOS 互操作客户端：**Rust 内核（CLI + 常驻守护进程）+ Tauri 状态栏 GUI**。
插入已登记密码的 EDP U 盘即**自动解密挂载**，无需每次 sudo、无需手输密码。

> ⚠️ **私有仓库，请勿公开**：本仓库包含 EDP 格式逆向知识与真实盘 fixture（含 wrapped key 材料与测试密码）。

## 功能特性

- **U 盘密码记录**：root-only AES-256-GCM 加密密码库，按 `(device_id, 分区类型)` 管理多条密码
- **逐盘授权自动挂载**：只有用户批准的 EDP 盘/分区才会自动挂载；普通 U 盘只读识别后忽略
- **状态栏 GUI**：Tauri 2 常驻 macOS 菜单栏，密码管理 / 会话管理 / 设置 / 日志
- **终端 CLI**：`usbcore` 一套命令完成 list/probe/mount/unmount/keys 等全部操作
- **透明读写**：SM4-ECB 透明解密 + macFUSE 桥 + 原生 exFAT 驱动，Finder 直接读写
- **密码双路径**：默认密码与用户修改后密码的验证逻辑分别实现（见 `docs/EDP-FORMAT.md`）

## 架构

```
launchd (root, KeepAlive)
 └─ usbcore daemon run              ← 守护进程（磁盘监听/密码库/自动挂载）
     ├─ DiskArbitration 监听
     ├─ 密码库 /var/db/edp-usbcore/store.enc（AES-256-GCM）
     ├─ UDS JSON-RPC /var/run/edp-usbcore.sock
     ├─ spawn: usbcore bridge       ← macFUSE 单文件桥（file_key 走匿名管道）
     └─ hdiutil attach → 原生 exFAT → /Volumes/...

usbcore <cmd>（终端 CLI）──┐
EDP USB Vault.app（菜单栏）───┴── 走 UDS socket 免 sudo
```

详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 环境要求

- macOS 13+
- [macFUSE](https://macfuse.github.io/)（**唯一**需要单独安装的组件，一次性；GUI 内置检测与引导）
- Rust 1.75+（仅构建期）

## 快速上手

**GUI（推荐）**——构建并运行状态栏客户端：

```bash
cd gui && npm ci && npx tauri dev     # 开发运行
# 或打包 .app：npx tauri build       # 产物在 gui/src-tauri/target/release/bundle/
```

GUI 首次使用：打开主窗口 → 设置页「安装后台服务」（弹系统授权）→ 设备页选择目标 U 盘 →
在分区行设置密码并开启逐盘授权。新盘默认不授权；daemon 安装后，**关闭窗口或退出 GUI
都不影响后台服务**。

## GitHub 自动构建

- 推送到 `main` 或手动运行 **macOS App** workflow，会完成 Rust/前端测试与严格 Clippy，随后构建 Apple Silicon (`arm64`) 客户端。
- 构建产物可从对应 Actions run 下载，包含保留 macOS 可执行权限的 `.app.zip`、可拖入“应用程序”的 `.dmg` 及 SHA-256 校验文件。
- 推送 `v*` 标签（例如 `v0.4.0`）会自动创建或更新 GitHub Release，并附加 arm64 安装包。
- 未配置 Apple Developer 证书时 CI 使用 ad-hoc 签名，不执行 Apple 公证；首次打开下载包可能需要在 Finder 中右键选择“打开”。

> **macOS 15（Sequoia）注意**：系统默认禁止后台守护进程访问可移动磁盘。安装 daemon 后
> 需**一次性**在「系统设置 → 隐私与安全性 → 完整磁盘访问权限」中添加
> `/usr/local/libexec/usbcore`，否则 daemon 无法读取 U 盘（GUI 设置页会提示）。
> `usbcore status` 输出 `disk_access_ok: false` 即表示未授予。

**CLI**：

```bash
make build
sudo target/release/usbcore mount /dev/rdisk4        # 手动挂载（输密码）
target/release/usbcore probe /dev/rdisk4             # 只读探测（密码/key/分区闭环）
target/release/usbcore status                        # daemon 在线状态
sudo make install                                    # 安装 launchd 守护进程（自动挂载）
target/release/usbcore keys add --disk /dev/rdisk4   # 录入密码（daemon 闭环验证）
```

daemon 在线时，`mount/unmount/mounts/keys` 等命令走 RPC，**无需 sudo**。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 进程模型、模块划分、数据流、安全模型 |
| [docs/EDP-FORMAT.md](docs/EDP-FORMAT.md) | EDP 格式逆向知识（LBA 布局/EDPF/算法/密码双路径） |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | UDS JSON-RPC 协议规范 |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 构建环境、代码结构、测试指南 |
| [docs/TESTING.md](docs/TESTING.md) | 测试策略与实盘检测清单 |

## 开发

```bash
make lint      # fmt + clippy（CI 同款门禁）
make test      # 单元测试
make test-integration  # 集成测试（sudo + macFUSE）
```

## License

私有项目，仅供研究与个人使用。
