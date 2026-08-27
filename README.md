# EDP USB Vault — macOS 26

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
  -> type 1: validated writable MBR/FAT slice
  -> type 2/4: per-partition Swift SM4 block adapter
  -> pinned FUSE-T 1.2.7 thin FSKit transport
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

构建不捆绑第三方 FUSE-T 二进制的原生安装包：

```bash
./installer/build-native-installer.sh artifacts
```

运行时严格校验 `/Applications/fuse-t.app` 的 bundle ID、Team ID 和已验证
1.2.7 可执行文件哈希。商业发布前必须取得适用的 FUSE-T commercial
license；在此之前不得将其二进制随商业产品分发。

原始磁盘访问不保存 `AuthorizationExternalForm`，也不修改 AuthorizationDB。
root 后台服务只接受经过签名校验的 App XPC 客户端，只对设备发现层确认过的
`/dev/rdiskN` 整盘执行 `O_RDWR`；root-owned `edp-console-exec` 将该文件描述符
固定继承为 fd 3，然后降权到当前控制台用户并启动 FUSE-T 桥。桥会再次校验
字符设备、设备大小、VID/PID、EDP 身份和分区元数据。安装及系统扩展批准完成
后，重启或重新插盘不再需要管理员密码。

正式发布前仍需在干净 macOS 26 机器完成“安装 → 系统批准 → 重启 → 无提示
自动挂载”的实体盘 E2E，作为发布验收项；这不是通过持久化临时授权令牌实现。

## 0.5.0 旧版 macFUSE/NTFS-3G 安装包

当前产品包不再依赖 iBoysoft，也不包含任何 iBoysoft 文件、授权数据或
提取组件。统一安装包包含：

- EDP Swift 可写透明块层；
- macFUSE 5.3.3 官方 FSKit 运行时组件；
- 从官方源码可复现构建的 NTFS-3G 2026.7.7；
- NTFS-3G 对应完整源码、GPL/LGPL 文本和 macFUSE 许可文本；
- `com.edp.usbvault.mountd` root LaunchDaemon 自动挂载服务。

文件系统分流保持明确：

```text
decrypted block device
  ├─ ExFAT -> Apple native ExFAT -> read/write
  └─ NTFS  -> ntfs-3g.probe --readwrite
             -> macFUSE backend=fskit -> read/write
```

NTFS 卷处于休眠、Windows Fast Startup、dirty journal 或不一致状态时，
服务拒绝写挂载；产品不使用 `force`、`recover` 或 `remove_hiberfile`。

构建组合安装包：

```bash
MACFUSE_DMG=/path/to/macfuse-5.3.3.dmg \
  ./installer/build-clean-installer.sh artifacts
./scripts/verify-clean-installer.sh \
  artifacts/EDP-USB-Vault-0.5.0-arm64-Clean.pkg
```

安装后先对每个 EDP 设备做一次本地密码登记：

```bash
sudo edp-vaultctl doctor
sudo edp-vaultctl list
sudo edp-vaultctl authorize diskN
```

密码验证成功后以 AES-GCM 加密保存于 root-only 的
`/var/db/com.edp.usbvault`。此后插入同一设备时，后台服务自动解锁并按
ExFAT/NTFS 类型读写挂载。`edp-vaultctl status` 可查看当前公开会话状态，
其中不含密码或派生密钥。

macFUSE 当前许可允许二进制再分发，但禁止未经书面许可随商业软件捆绑；
因此这个组合安装包只适用于本项目声明的非商业分发。若用途变为商业，
必须先取得 macFUSE 商业许可。

## 唯一架构

```text
real EDP USB
  -> LBA11/LBA12 / password / derived key
  -> Swift SM4 transparent block translation
  -> EDPBlockReadable
  -> macFUSE 5.x (backend=fskit)
  -> hidden volume.raw
  -> Private DiskImages2
  -> /dev/diskN / IOMedia
  -> macOS native filesystem stack
  -> Finder
```

EDP USB Vault **不自行实现 exFAT/APFS/FAT/NTFS 等任何具体文件系统**。项目只负责 EDP metadata、身份/密码校验、key derivation、SM4、offset/length block translation 和 mount lifecycle。

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
