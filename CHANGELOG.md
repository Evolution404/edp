# Changelog

本项目的所有显著变更记录于此。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- M0：Cargo workspace 骨架（edp-core / edp-macos / edp-proto / usbcore）
- M0：CI（macOS 全 workspace + Ubuntu edp-core 跨平台回归）、Makefile、rustfmt/clippy 门禁
- M0：文档骨架（README + docs 五篇 + CHANGELOG）
- M0：真实盘 fixture（disk4 Lexar / disk5 SanDisk）与黄金测试数据（Python 参考实现一次性离线生成，项目本身零 Python 依赖）
- M1：edp-core 加密格式层（crc32 / rolling-XOR / 手写 A6B0/A7F0 AES / 手写 SM4-ECB）与黄金逐字节对照
- M1：LBA7 密码认证（双路径：默认密码 CRC + 固定种子 file_key）、LBA11 PDKB device_id、LBA12 EDPF 解析与 file_key 解包
- M1：device_id 三级发现（explicit → LBA11 → identify 兜底；disk5 天然回归用例）
- M1：usbcore CLI 离线模式（list/doctor/login/probe/mount/unmount/mounts）+ fuser 单文件桥 + `-owners off` 挂载链
- M1：合成盘集成测试（`#[ignore]`，sudo + macFUSE）+ 两块真实盘 4 分区挂载验收
- M2：edp-proto UDS JSON-RPC（PEERCRED 鉴权 / 事件广播 / 协议测试）
- M2：usbcore daemon（磁盘轮询 diff、AES-256-GCM 密码库、自动挂载状态机、RPC server、launchd 安装）
- M2：密码库 `keys` 子命令（在线，脱敏输出，store.enc 无明文）
- M2：CLI 在线模式（mount/unmount/mounts/status/doctor 走 RPC 免 sudo，离线降级）
- M2：daemon 授权白名单自动派生（root 守护进程放行控制台用户；非 root 放行自身）
- M2：CLI 在线模式协议测试（`online_mode`，非 root 可跑，无 macFUSE 依赖）
- M3：Tauri 2 + Vue 3 状态栏 GUI（tray 常驻 / 无 Dock / 四页面：挂载、密码库、设置、日志）
- M3：GUI 事件订阅（mounted/unmounted/… → 前端 + 系统通知 + 托盘动态菜单）
- M3：macFUSE 检测引导 / daemon 提权安装 / 密码库一键挂载
- M3：GUI 独立 cargo workspace + CI GUI job（前端构建 + 后端 clippy/build/bundle）

### Fixed
- M2：daemon 默认授权白名单为空导致非 root 客户端全被拒——改为按运行身份自动派生
- M2：服务端事件推送仅在请求循环顶部 try_recv，长连接订阅事件积压——改为专用推送线程
- M3：tauri 配置 activationPolicy/signingIdentity 位置修正（运行时 set_activation_policy + bundle.macOS）
