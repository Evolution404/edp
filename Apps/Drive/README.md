# EDP Drive — macOS 26

本分支维护 **macOS 26+ 原生菜单栏产品方向**。

## 0.6.0 原生菜单栏产品

0.6.0 使用 SwiftUI、AppKit、XPC、Disk Arbitration 和 System Keychain，
不依赖 Tauri 或 WebView。应用设置为 `LSUIElement`，常驻菜单栏且不显示
Dock 图标；菜单栏可以打开完整的“设备 / 活动 / 设置”主界面。

每个已识别设备按三个分区独立管理：

- type 1 启动区：普通分区，无密码，默认自动挂载；
- type 2 交换区：独立密码和自动挂载策略；
- type 4 保密区：独立密码和自动挂载策略。

交换区和保密区使用各自的 System Keychain 项目。旧版单设备密码会在
首次启动 0.6 服务时迁移为两个分区级项目。设备名称和挂载策略为全机共享，
保存在 root-only 的原子策略文件中。

正式挂载链为：

```text
physical EDP USB
  -> FDA daemon retains one validated O_RDWR whole-disk fd
  -> type 1: plaintext writable MBR/FAT slice
  -> type 2/4: shared EDPCore SM4 block adapter
  -> macFUSE 5.3.3 Local FSKit transport (local,nobrowse)
  -> hidden writable volume.raw
  -> DiskImages2 writable virtual media
  -> Apple native filesystem stack
  -> Finder
```

ExFAT 由 Apple 原生读写。NTFS 可以按系统能力只读挂载，但虚拟磁盘介质
保持可写，因此 Finder 自带的“抹掉”可以把交换区或保密区格式化为 ExFAT；
应用本身不提供破坏性的格式化按钮。

整盘以 `O_RDWR` 打开后，macOS 会撤掉实体启动分区的子设备节点，因此 type 1
也由受限的明文 MBR 切片发布为虚拟 FAT 卷。这样启动区、交换区、保密区可以
同时存在，且仍由同一会话生命周期统一卸载和安全推出。

产品 transport 只支持 macFUSE Local，不存在可切换的备用 transport backend。
组合安装包包含并校验官方 macFUSE 5.3.3 安装组件：

```bash
./installer/build-clean-installer.sh artifacts
```

运行时严格校验 `/Library/Filesystems/macfuse.fs` 中的签名、TeamIdentifier、
MFMount.framework 和 Local FSKit module；前台 App 只负责当前控制台用户的
FSKit module enablement，root daemon 不修改用户的 FSKit 设置。

原始磁盘访问不保存 `AuthorizationExternalForm`，也不修改 AuthorizationDB。
安装包只部署 `/Applications/EDP Drive.app`；无 UI 的签名服务位于
`Contents/Library/LaunchServices/edp-drive-service`，不会作为第二个 App 出现在
应用列表。首次配置时，用户只需要为这一固定 App/embedded-service 组合开启一次
Full Disk Access。root 后台服务先通过 IOKit 与只读 metadata helper 识别 EDP
whole USB，再由 embedded service 对当前
`/dev/rdiskN` 进行二次 whole-USB、字符设备、device-node 一致性以及 LBA4/LBA7
EDP 元数据校验。校验通过后才以 `O_RDWR` 打开整盘，将 fd 固定继承为 3，随后
降权到当前控制台用户并启动加密 transport。正式路径不再使用
`sys.openfile.*` / `authopen`，因此 U 盘拔插和 `diskN` 变化不依赖 300 秒授权缓存。

正式发布前仍需用同一稳定 self-signed certificate 完成“首次 FDA → App/daemon
重启 → U 盘拔插与 diskN 变化 → Mac 重启 → 版本升级仍无重复授权”的实体盘 E2E。
当前本机统一签名身份为 `EDP Project Code Signing`，证书 SHA-256 为
`D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7`，
designated requirement 的 certificate root 为
`040b5488fb2b6c02b0786e76b674cb4460658ca2`。EDP Drive 与 EDP Studio
统一使用这张证书；本地 self-signed 包必须通过
`./installer/build-self-signed-installer.sh` 构建，该入口会校验证书 fingerprint
和私钥匹配关系，不再使用 Apple Development identity。
详细设计与当前验收状态见 `docs/PLAN-2026-08-29-fda-raw-access.md`。

首次安装/完全清理/重启/三分区读写/策略 round-trip/安全推出的标准化验收流程见
`docs/FIRST-INSTALL-ACCEPTANCE.md`，可执行入口为：

```bash
./scripts/first-install-acceptance.sh --help
```

## 文件系统策略

EDP Drive 不再捆绑或调用 `ntfs-3g`。所有文件系统语义都交给 macOS 原生文件系统栈处理：

```text
decrypted block device
  -> DiskImages2
  -> macOS native filesystem stack
  -> Finder
```

ExFAT/FAT 等由系统按原生能力挂载；NTFS 仅按 macOS 当前提供的能力挂载，产品不再提供第三方 NTFS 写入层。若用户需要写入，可在 Finder/磁盘工具中将对应虚拟介质抹掉为系统原生可写格式（例如 ExFAT）。

## 唯一架构

```text
real EDP USB
  -> LBA11/LBA12 / password / derived key
  -> shared EDPCore SM4 transparent block translation
  -> EDPBlockReadable
  -> macFUSE 5.x (backend=fskit)
  -> hidden volume.raw
  -> Private DiskImages2
  -> /dev/diskN / IOMedia
  -> macOS native filesystem stack
  -> Finder
```

EDP Drive **不自行实现 exFAT/APFS/FAT/NTFS 等任何具体文件系统**。应用只负责 raw-device 生命周期、挂载和系统集成；EDP metadata、身份/密码校验、key derivation 与 SM4 由 monorepo 的 `Packages/EDPCore` 统一提供。

产品 runtime 不使用 `hdiutil`，不使用 DriverKit block-storage entitlement，不使用 macFUSE kernel backend，也不要求关闭 SIP 或降低 Apple Silicon 启动安全策略。

## 已完成的读写 E2E

### 1. macFUSE FSKit + DiskImages2 块桥

GitHub Actions run `32848875297` 在 macOS 26.5.2 / Apple Silicon / macFUSE 5.3.3 上完整跑通：

```text
random-access backing
  -> macFUSE FSKit volume.raw
  -> Private DiskImages2
  -> /dev/disk8
  -> Apple native ExFAT
  -> file write/read
  -> unmount/eject
```

最终 marker：

```text
RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK
```

### 2. Swift EDP crypto read-only 数据路径

GitHub Actions run `32851503960` 又进一步把真实 Swift crypto reader 放进数据路径：

```text
128 MiB plaintext native filesystem image
  -> EDPSM4 encrypt whole image
  -> cipher.img
  -> EDPFileRawDevice / pread
  -> EDPEncryptedPartitionReader
  -> EDPEncryptedReadOnlyBlockDevice
  -> macFUSE FSKit volume.raw
  -> DiskImages2 explicit read-only attach
  -> /dev/disk8 (Media Read-Only: Yes)
  -> Apple native filesystem
  -> proof.txt + payload.bin
```

验证内容包括：

- 多个非 16-byte 对齐 random windows 与原始 plaintext 完全一致；
- DiskImages2 成功发布 read-only BSD disk；
- Apple 原生 filesystem 成功读取文件；
- 4 MiB payload 的 expected/actual SHA-256 完全一致；
- 写入尝试被拒绝；
- unmount/eject 正常。

最终 marker：

```text
RESULT=EDP_CRYPTO_MACFUSE_DISKIMAGES2_NATIVE_FS_READ_E2E_OK
```

这证明现有 `EDPEncryptedPartitionReader` 可以作为透明块层直接服务 Apple 原生文件系统，不需要自己实现 exFAT。

### 3. Swift EDP crypto 可写数据路径

2026-08-26 在 macOS 26.6.2 / Apple Silicon / macFUSE FSKit 上完成：

```text
native ExFAT image
  -> whole-image SM4 ciphertext
  -> EDPEncryptedReadWriteBlockDevice
  -> macFUSE FSKit writable volume.raw
  -> DiskImages2 writable /dev/diskN
  -> native filesystem file write + sync
  -> eject / bridge process exit
  -> bridge restart / reattach / SHA-256 readback
```

最终 marker：

```text
RESULT=EDP_CRYPTO_DISKIMAGES2_NATIVE_FS_READWRITE_E2E_OK
```

已覆盖 SM4 非 16-byte 对齐写入的 read-modify-write、越界拒绝、串行化、`pwrite`、`fsync` / `F_FULLFSYNC`、FUSE `write/flush/fsync`，并确认写入后 ciphertext 哈希发生变化、完整重挂载后 4 MiB 文件哈希一致。

NTFS 目录/文件语义仍由外部 NTFS 驱动承担。本机 iBoysoft 4.5 能识别可写 DiskImages2 介质，但当前实测强制返回 `Volume Read-Only: Yes`；因此不能把块层 E2E 写成“真实 EDP NTFS 已写入成功”。驱动恢复读写后，可直接复用同一可写块路径。

## 重要证据边界

第二级 E2E 使用的是 synthetic encrypted whole-disk fixture 和 deterministic test key，**不是实际物理 EDP U 盘数据区**。

因此当前唯一 P0 gate 是：

```text
real EDP USB
  -> actual LBA11/LBA12
  -> actual password + derived key
  -> actual encrypted data region
  -> existing Swift decrypted block path
  -> macFUSE FSKit
  -> DiskImages2 --readonly
  -> Apple native filesystem
  -> Finder read
```

真实盘只读闭环已完成；可写块路径和 privileged raw-device fd 3 交接已经实现。
真实 NTFS 文件写入仍取决于 Apple 当前提供的只读能力；产品通过保持虚拟介质
可写来支持 Finder 将该分区抹掉并重新格式化为 ExFAT。

## 当前核心模块

纯 Swift core 已包含：

- LBA4/LBA7 recognition；
- LBA11 device identity；
- LBA12 metadata / partition descriptor；
- CRC32；
- password/key validation；
- SM4；
- arbitrary unaligned encrypted reads；
- arbitrary unaligned encrypted read-modify-write；
- `EDPEncryptedPartitionReader`；
- `EDPBlockReadable` / `EDPBlockWritable`；
- `EDPEncryptedReadOnlyBlockDevice` / `EDPEncryptedReadWriteBlockDevice`；
- `EDPFileRawDevice` exact `pread` / `pwrite` / sync adapter；
- 3,200 deterministic property/random cases + golden/negative tests。

Private DiskImages2 使用集中在 bridge 中并通过 runtime class/selector probe 调用；不兼容时必须 fail closed。

## 永久系统级回归

```text
.github/workflows/macfuse-diskimages2-poc.yml
.github/workflows/edp-crypto-diskimages2-readonly.yml

native/EDPFSKitPoC/Tools/DiskImages2Attach.m
native/EDPFSKitPoC/Tools/EDPReadOnlyBlockCBridge.swift
native/EDPFSKitPoC/Tools/EDPReadOnlyFuseBridge.c
native/EDPFSKitPoC/Tools/EDPReadWriteBlockCBridge.swift
native/EDPFSKitPoC/Tools/EDPReadWriteFuseBridge.c
native/EDPFSKitPoC/Tools/probe-edp-crypto-diskimages2.sh
native/EDPFSKitPoC/Tools/probe-edp-crypto-diskimages2-readwrite.sh
```

完整状态、证据边界和后续实施顺序见 [`docs/STATUS.md`](docs/STATUS.md)。
