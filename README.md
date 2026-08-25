# EDP USB Vault — macOS 26 Native FSKit

本分支 `feat/macos26-native-fskit` 只维护 **macOS 26+ 原生实现**。

目标：Swift/SwiftUI + Apple FSKit，最终做到原生 App、一键安装，不依赖 macFUSE、Rust bridge 或常驻 helper daemon。

## 当前架构

```text
FSKit / fskitd
  -> FSBlockDeviceResource
  -> FSBlockRawAccessor
  -> EDPRawReadable
  -> EDP metadata / key derivation / SM4 translation
  -> EDPEncryptedPartitionReader
  -> read-only filesystem semantics
  -> FSVolume
```

Apple 公开 FSKit API 当前没有受支持的方式把任意解密后的字节流重新包装成新的 real `FSBlockDeviceResource` 再交给系统内置 exFAT FSKit 模块，因此产品方案不依赖 FSKit module chaining。

## 当前状态

已经完成：

- macOS 26.0+ SwiftUI Host App + FSKit File System Extension 骨架；
- `com.apple.developer.fskit.fsmodule` entitlement 与 block-resource 声明；
- `Contents/Extensions` 正确嵌入、ad-hoc 签名、PluginKit 注册和 hosted contract；
- `FSBlockDeviceResource` 对齐读取适配层；
- Swift 原生 EDP LBA4/LBA7 识别；
- Swift 原生 LBA11/LBA12、CRC32、SM4、密码/key 校验、分区描述；
- `EDPEncryptedPartitionReader`；
- 3,200 个 deterministic property/random cases + golden/negative regressions；
- macOS 15-target 的真实 EDP 数据采集工具及端到端 CI；
- 当前稳定 SDK 下的只读 `FSVolume` compile contract。

当前唯一不能由 GitHub hosted runner 越过的关键门槛是 **用户批准第三方 File System Extension**。Hosted runner 已证明 bundle/注册/原始块调用链到达系统批准边界，但会得到：

```text
Module com.edp.usbvault.fskit-poc.extension is disabled!
```

因此 `EDPFileSystem.loadResource` 目前仍故意返回 `ENOTSUP`；在正常 macOS 26 机器通过 approved-runtime gate 前，不提前接完整 `FSVolume`。

## CI

保留四条有效工作流：

- **Native Swift Fast Checks**：Swift core、3,200 随机/性质测试、source graph、macOS 15 capture tool、capture E2E；
- **Native FSKit Hosted Contract**：一次完整 Xcode build + bundle/sign/register/PluginKit/raw-block approval-boundary contract；
- **Native FSKit SDK Surface**：低频检查 runner 实际 Swift FSKit API；
- **Native FSKit Approved Runtime Gate**：正常、已批准扩展的 macOS 26 self-hosted 机器运行最终 runtime gate。

详见 [`docs/STATUS.md`](docs/STATUS.md)。

## 当前开发规则

1. 不重新引入 macFUSE。
2. 不重新引入 Rust/C ABI bridge。
3. 不增加 helper daemon 作为文件系统数据路径依赖。
4. `FSBlockRawAccessor` 是唯一 FSKit-specific raw-device adapter。
5. 文件系统语义与 FSKit I/O 解耦，先实现可独立测试的 read-only backend。
6. 写支持必须晚于 read-only mount/read/unmount 正确性。

## 目录

```text
.github/workflows/     当前 native CI gates
native/EDPFSKitPoC/    Host、FSKit Extension、Swift core 与工具
fixtures/              golden vectors 与真实 EDP reserved-sector captures
docs/STATUS.md         当前唯一项目状态/交接文档
```
