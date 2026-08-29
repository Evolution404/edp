# EDPOpen macOS 26 原生迁移计划

日期：2026-08-29
分支：`feat/native-macos26`

## 目标架构

```text
EDPOpen.app (SwiftUI + AppKit, macOS 26+)
    │
    ├─ Native UI
    │   ├─ NavigationSplitView / Inspector / Toolbar
    │   ├─ Liquid Glass
    │   ├─ Disk Map (SwiftUI Canvas / Shape)
    │   └─ Sector Hex Viewer (AppKit NSView)
    │
    ├─ EDP Core Bridge
    │   └─ Rust static library / C ABI
    │       ├─ crypto
    │       ├─ parser
    │       ├─ convert
    │       └─ editor
    │
    └─ Raw Device Broker (后续)
        ├─ Swift system LaunchDaemon
        ├─ stable certificate-backed identity
        ├─ Full Disk Access
        ├─ Disk Arbitration + IOKit validation
        └─ narrow IPC, no arbitrary-path open
```

旧 Tauri 应用保留为功能参考与回归基线，不作为最终 UI。

## Phase A — 原生视觉 PoC

- [x] XcodeGen 原生工程，最低 macOS 26.0
- [x] SwiftUI `NavigationSplitView`
- [x] macOS 26 `glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)`
- [x] 原生 Overview
- [x] 原生 Disk Map
- [x] AppKit 自绘 512-byte Hex Viewer
- [x] byte hover / selection / keyboard navigation
- [x] Inspector 字段上下文
- [x] Xcode 26.6 build 通过
- [x] 本机启动视觉 PoC

Phase A 严格离线，不枚举/读取真实 U 盘。

## Phase B — Rust EDP Core 收口

- [x] 从 Tauri 门面中抽离纯 EDP format engine：`crypto/parser/editor/convert/sector/Identity` 已进入 `core/edpopen-core`
- [x] 建立稳定、窄 C ABI：独立 `core/edpopen-ffi` staticlib，当前公开 version/CRC32/sector decode JSON/free
- [x] Swift wrapper：`CoreBridge.swift` + bridging header；Xcode build phase 自动构建 Rust release staticlib
- [x] 使用现有 golden 复核 crypto/parser/editor/convert；旧 Tauri 继续通过同一份 core 源码回归
- [x] Native UI 用 Rust Core 驱动离线样例：LBA0 的 MBR 字段/语义着色由 Rust parser 返回，Inspector 显示 core 字段和值

原则：不重写已通过真实盘 golden 的密码学/重加密算法。旧 Tauri 中 `crypto.rs/parser.rs/editor.rs` 仅保留 re-export；`convert.rs` 仅保留授权、备份、还原和写事务，纯 ConvertPlan 已迁入 core。

## Phase C — Swift FDA Raw Broker

前置 PoC 证据：`poc/fda-raw-broker/RESULTS-2026-08-29.md`。

- [x] 独立 Swift broker target：`EDPOpenRawBroker`
- [x] system LaunchDaemon plist / 固定目标路径已定义；尚未正式安装验证
- [x] stable certificate-backed signing identity：App=`com.evolution404.edpopen`、Broker=`com.evolution404.edpopen.rawbroker`，Team=`W82WPH8HY7`，Apple Development + Hardened Runtime，DR 均非 CDHash
- [x] FDA readiness probe 代码：仅 `open(O_RDONLY|O_CLOEXEC) → fstat → close`，不读取扇区
- [x] Disk Arbitration + IOKit external/physical/USB/whole-disk gate
- [ ] EDP metadata verification before exposing device session
- [x] narrow NSXPC IPC, no arbitrary path API；broker 只接受数字 `diskN`
- [x] App/broker 双向 `setCodeSigningRequirement()`，绑定 bundle identifier + Team `W82WPH8HY7`
- [ ] 同一 open fd/session 复用

## Phase D — 只读实机接入

- [ ] GUI 枚举真实 U 盘
- [ ] broker read-only metadata session
- [ ] Overview / Map / Sector 使用真实数据
- [ ] App 重启无授权
- [ ] daemon 重启无授权
- [ ] U 盘拔插 / diskN 改变无授权

## Phase E — 写入/还原迁移

- [ ] 现有备份/MD5/LBA4 ID 安全模型迁移
- [ ] convert transaction 迁移到 broker
- [ ] editor save transaction 迁移到 broker
- [ ] restore transaction 迁移到 broker
- [ ] 删除 `authopen` / `sys.openfile.*`

## Phase F — 安装与发布

- [ ] 首次安装 privileged broker
- [ ] FDA 设置页引导和 readiness 检测
- [ ] App + broker 稳定签名
- [ ] designated requirement 升级连续性测试
- [ ] 5min / 30min / reboot / app upgrade 验收
