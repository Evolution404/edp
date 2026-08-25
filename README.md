# EDP USB Vault — macOS 26

本分支 `feat/macos26-native-fskit` 维护 **macOS 26+** 产品方向。

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

## 已完成的两级 E2E

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

真实盘只读闭环通过之前，不实现写支持。

## 当前核心模块

纯 Swift core 已包含：

- LBA4/LBA7 recognition；
- LBA11 device identity；
- LBA12 metadata / partition descriptor；
- CRC32；
- password/key validation；
- SM4；
- arbitrary unaligned encrypted reads；
- `EDPEncryptedPartitionReader`；
- `EDPBlockReadable` / `EDPEncryptedReadOnlyBlockDevice`；
- `EDPFileRawDevice` exact `pread` adapter；
- 3,200 deterministic property/random cases + golden/negative tests。

Private DiskImages2 使用集中在 bridge 中并通过 runtime class/selector probe 调用；不兼容时必须 fail closed。

## 永久系统级回归

```text
.github/workflows/macfuse-diskimages2-poc.yml
.github/workflows/edp-crypto-diskimages2-readonly.yml

native/EDPFSKitPoC/Tools/DiskImages2Attach.m
native/EDPFSKitPoC/Tools/EDPReadOnlyBlockCBridge.swift
native/EDPFSKitPoC/Tools/EDPReadOnlyFuseBridge.c
native/EDPFSKitPoC/Tools/probe-edp-crypto-diskimages2.sh
```

完整状态、证据边界和后续实施顺序见 [`docs/STATUS.md`](docs/STATUS.md)。
