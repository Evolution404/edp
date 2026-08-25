# macOS 26 Native FSKit — 当前状态与唯一实施方案

更新时间：2026-08-25  
分支：`feat/macos26-native-fskit`

> 本文件是该分支唯一的状态、架构和后续实施交接文档。旧 Rust/Tauri/macFUSE 架构、macOS 15 FSKit 排障文档和一次性实验记录已从本分支移除；需要历史细节时使用 Git 历史，不再把旧方案作为当前文档保留。

## 1. 产品目标

目标平台仅为 **macOS 26+**：

- 原生 Swift/SwiftUI App；
- 自有 Apple FSKit File System Extension；
- 最终一键安装/首次批准后正常使用；
- 不依赖 macFUSE；
- 不依赖 Rust/C ABI bridge；
- 不依赖常驻 helper daemon 完成文件系统数据路径。

macOS 15.x 已退出产品兼容目标。15.7.9 机器只保留一个用途：在不依赖 FSKit 的情况下读取真实 EDP U 盘，采集非敏感 cipher/plain regression evidence。

## 2. 最终架构

```text
FSKit / fskitd
  -> real FSBlockDeviceResource
  -> FSBlockRawAccessor
  -> EDPRawReadable
  -> EDP metadata / device identity / password verification
  -> key derivation + SM4 translation
  -> EDPEncryptedPartitionReader
  -> pure Swift read-only filesystem backend
  -> FSVolume adapter
  -> Finder / normal macOS file access
```

边界规则：

- `FSBlockRawAccessor` 是唯一直接依赖 `FSBlockDeviceResource` 的原始设备适配层；
- metadata/crypto/partition reader 只依赖 Swift storage abstraction；
- filesystem namespace/read semantics 不直接依赖 FSKit；
- `FSVolume` 只做 Apple FSKit API adapter；
- 写入能力在 read-only mount/read/unmount 稳定前不实现。

### 为什么不把解密块交给 Apple 内置 exFAT FSKit

当前公开 FSKit API 没有受支持的接口可以：

1. 把 EDP 解密后的任意字节流包装成第二个 real `FSBlockDeviceResource`；
2. 再把这个虚拟 block resource 链给 Apple 内置 exFAT FSKit module。

因此不把 module stacking 作为产品依赖。若 Apple 未来公开这类能力，可重新评估；当前方案是自有 read-only filesystem semantics。

## 3. 已完成实现

### 3.1 Native FSKit skeleton

已完成：

- SwiftUI Host App；
- FSKit File System Extension；
- minimum macOS `26.0`；
- `com.apple.developer.fskit.fsmodule` entitlement；
- `FSSupportsBlockResources = true`；
- ExtensionKit/FSKit extension point 配置；
- extension 正确嵌入 `Contents/Extensions`；
- Xcode 26.6 / macOS 26 runner 构建成功；
- ad-hoc signing 成功；
- PluginKit 能索引第三方 FSKit module。

### 3.2 Live raw-block probe

`EDPFileSystem.probeResource` 已实现：

```text
FSBlockDeviceResource
  -> FSBlockRawAccessor
  -> exact aligned byte read
  -> LBA4/LBA7
  -> Swift EDP reserved-sector recognition
  -> FSProbeResult.recognized
```

当前 `loadResource` **故意返回 `ENOTSUP`**。这是 evidence gate，不是遗漏：在正常 macOS 26 上证明 extension 获得真实 block resource 前，不把完整 volume 接入 runtime。

### 3.3 Pure Swift EDP core

当前 native Swift 已包含：

- aligned window calculation；
- exact aligned segmented read loop；
- LBA4 serial / LBA7 reserved-sector recognition；
- LBA11 device identity；
- LBA12 decode / partition descriptor parsing；
- CRC32；
- EDP password/key validation；
- SM4；
- encrypted partition byte translation；
- `EDPEncryptedPartitionReader`。

Native target 不链接、不调用 Rust 或旧 C ABI bridge。

### 3.4 Read-only FSVolume API contract

已有 compile-only `EDPReadOnlyVolumeContract`，按当前稳定 Xcode 26.6 / MacOSX26.5 SDK 编译：

- `FSVolume.PathConfOperations`；
- `FSVolume.Operations`；
- `FSVolume.ReadWriteOperations`；
- root activation；
- attributes / lookup / enumerate / read API shape；
- 所有 mutation 返回 `EROFS`。

它目前不从 `loadResource` 返回，也还不是文件系统实现。

当前 runner 编译探针结果：

```text
FSKIT_SDK_VOLUME_OPERATIONS=true
FSKIT_SDK_READ_WRITE_OPERATIONS=true
FSKIT_SDK_VOLUME_HANDLER=false
FSKIT_SDK_READ_WRITE_HANDLER=false
FSKIT_SDK_CLIENT_DIRECT_SETTINGS=false
```

Apple 网页文档可能先于稳定 SDK；生产代码以 runner 实际 compiler-visible SDK 为准。`Native FSKit SDK Surface` 每周/手动检查一次未来 API 迁移时机。

## 4. 测试与证据

### 4.1 Fast deterministic coverage

当前 Fast Checks 保留 **3,200 个 deterministic property/random cases**：

```text
1,280  aligned-window properties
  384  aligned continuation properties
  512  production aligned-read progression properties
1,024  real-derived-key encrypted-reader windows
-----
3,200  total
```

此外还有固定 golden vectors、CRC32/SM4、metadata negative paths、bounds/overflow、malformed metadata 等回归。

### 4.2 真实 EDP metadata 证据

仓库保留真实设备 captured reserved sectors，例如 disk4/disk5 的 LBA4/LBA7/LBA11/LBA12。Swift core 已使用这些数据验证：

- reserved signature；
- device identity；
- LBA12 decode；
- password/key derivation；
- 两块真实盘派生 key 下的 randomized encrypted-reader behavior。

### 4.3 数据区证据边界

目前仓库 **没有提交真实 EDP 数据分区 cipher/plain pair**。

现有 E2E 是：

```text
真实 disk4 LBA11/LBA12
  -> 真实派生 file key
  -> deterministic synthetic plaintext
  -> SM4 ciphertext
  -> raw EDP test image
  -> macOS 15-target CaptureEDPDataFixture
  -> 重新解析 metadata / 重新派生 key / 解密
  -> cipher cmp + plain cmp
```

因此可以证明采集器和 native translation chain 正确，但不能把它表述成“真实 U 盘数据区密文已经验证”。

## 5. macOS 15.7.9 真实数据采集工具

`native/EDPFSKitPoC/Tools/CaptureEDPDataFixture.swift`：

- source device `O_RDONLY`；
- 只使用 `pread`；
- 不写 U 盘；
- 不输出 password/file key；
- 人工运行时密码无回显输入；
- 默认采集 64 KiB，最大 8 MiB；
- 输出目录建议 `.edp-captures/`，已被 Git ignore；
- CI 明确以 `arm64-apple-macosx15.0` deployment target 编译；
- CI 已完整跑通 synthetic-data-area E2E。

构建：

```bash
bash native/EDPFSKitPoC/Tools/build-capture-tool.sh
```

真实采集前先确认 disk/VID/PID/size，优先使用不含敏感内容的专用测试 EDP U 盘。不要在审阅明文前把 capture 提交到公开仓库。

## 6. CI 结构

本分支只保留四个 native workflow。

### Native Swift Fast Checks

用途：普通 Swift core/source changes。

包含：

- 3,200 property/random cases；
- golden/negative regressions；
- extension/host/FSClient compile checks；
- read-only FSVolume contract typecheck；
- macOS 15 capture tool compile；
- capture tool E2E。

近期 hosted-runner 总时间约 **20–24 秒**，主要波动来自 Swift compiler startup。

### Native FSKit Hosted Contract

用途：只有 project/bundle/entrypoint/entitlement 等变化才运行重 build。

验证：

- XcodeGen；
- 单次完整 host + extension build；
- bundle contract；
- pure Swift/native independence；
- ad-hoc signing；
- install/register；
- PluginKit indexing；
- EDP-seeded raw block mount classification。

近期代表数据：

- end-to-end：约 **58–61 秒**；
- clean `xcodebuild`：最新约 **35 秒**；
- 旧重复 heavy workflows 合计约 152 runner-seconds，现 heavy runner consumption 已下降约 **60–62%**。

Hosted runner 当前预期边界：

```text
Module com.edp.usbvault.fskit-poc.extension is disabled!
```

### Native FSKit SDK Surface

低频/手动 compiler capability probe，不拖慢日常 Fast Checks。

### Native FSKit Approved Runtime Gate

运行于正常、已由用户批准 EDP File System Extension 的 Apple Silicon macOS 26 self-hosted Mac。

## 7. 当前唯一关键 runtime gate

必须在正常 macOS 26 机器上启用 EDP File System Extension 后得到：

```text
FSKIT_MODULE_FOUND=com.edp.usbvault.fskit-poc.extension
FSKIT_MODULE_ENABLED=true
PROBE_BLOCK_DEVICE=diskN
PROBE_RESERVED_SECTORS_READ=true
PROBE_CORE=swift-native
PROBE_EDP_RESERVED_SIGNATURE=true
PROBE_MATCH=recognized
RESULT=NATIVE_FSKIT_SWIFT_CORE_RECOGNIZED:diskN
```

仓库入口：

```bash
bash native/EDPFSKitPoC/Tools/verify-approved-runtime.sh
```

GitHub-hosted runner 无法代替这一步，因为用户 approval 是系统交互/策略边界。

## 8. 接下来实施顺序

在不等待 approved runtime 的情况下，可以继续：

1. 定义纯 Swift read-only filesystem backend protocol/model；
2. 实现并单测 `root / lookup / enumerate / attributes / read`，保持与 FSKit 解耦；
3. 从 15.7.9 测试机采一组经过审阅的真实 EDP data-area cipher/plain evidence；
4. 为真实 decrypted boot/data structures 增加永久 regression tests。

获得 approved macOS 26 runtime 后：

5. 把 live FSKit block resource 的 LBA11/LBA12 + crypto translation 接通；
6. 证明通过 live resource 能读出正确 decrypted bytes；
7. 将 read-only backend 接到最小 `FSVolume`；
8. 验证 mount → lookup/enumerate/read → teardown/unmount；
9. read-only 稳定后再讨论 write support。

## 9. 明确废弃的路径

本分支不再继续：

- macOS 15 产品兼容；
- macFUSE mount backend；
- Rust core / Tauri GUI；
- helper daemon 数据路径；
- Rust-to-Swift C ABI bridge；
- 修改 `enabledModules.plist` 绕过用户 approval；
- signing A/B 与 macFUSE 对照实验；
- 自定义 Swift exFAT reader 的早期试验版本；
- 假设可以把 EDP 解密数据链给 Apple 内置 exFAT FSKit 的未公开 module-stacking 方案。

历史调查仍存在 Git history 中，但不再保留为当前分支文件，以免误导后续开发。

## 10. 清理后的分支结构

```text
.github/workflows/
  native-fskit-approved-runtime.yml
  native-fskit-core-probe.yml
  native-fskit-hosted-contract.yml
  native-fskit-sdk-surface.yml

native/EDPFSKitPoC/
  Host/
  Extension/
  Tools/
  project.yml

fixtures/
  golden/
  real_disks/

docs/
  STATUS.md

README.md
.gitignore
```

这就是后续开发的基线。任何新方案若与本文冲突，应先更新本文并说明证据，再修改主实现。
