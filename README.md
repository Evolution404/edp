# EDP USB Vault — macOS 26

本分支 `feat/macos26-native-fskit` 只维护 **macOS 26+** 方案。

当前产品方向已经通过 macOS 26 Apple Silicon CI 完整验证：

```text
EDP encrypted partition
  -> password / key / SM4 transparent block translation
  -> macFUSE 5.3.3 (backend=fskit)
  -> hidden volume.raw
  -> Private DiskImages2
  -> /dev/diskN / IOMedia
  -> macOS native filesystem stack
  -> Finder
```

## 核心原则

EDP USB Vault **不自行实现 exFAT/APFS/FAT 等文件系统**。

项目只负责：

- EDP metadata；
- 设备身份与密码校验；
- key derivation；
- SM4 加解密；
- offset/length block translation；
- mount/unmount lifecycle。

具体文件系统继续由 macOS 原生实现负责。

## 已验证的关键架构

2026-08-25，GitHub Actions 在：

```text
macOS 26.5.2 (25F84)
Apple Silicon
Xcode 26.6
macFUSE 5.3.3
```

完整跑通：

```text
macFUSE FSKit backing
  -> DiskImages2 attach
  -> /dev/disk8
  -> native ExFAT format
  -> /Volumes/EDPDI2TEST
  -> write proof.txt
  -> read proof.txt
  -> unmount
  -> eject
```

最终标记：

```text
RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK
```

这证明 `macFUSE FSKit + Private DiskImages2` 可以把用户态透明随机读写文件桥接成系统真实 BSD block device，并继续使用 Apple 原生文件系统。

PoC runtime **没有调用 `hdiutil`**，也没有使用 DriverKit block-storage entitlement。

## 为什么使用 DiskImages2

macFUSE FSKit 能暴露高质量 random-access regular file，但它本身不会创建 `/dev/diskN`。

Private `DiskImages2.framework` 正好补上：

```text
regular file -> Apple disk image stack -> IOMedia -> BSD disk
```

它是私有 API，因此产品必须：

- 通过 `dlopen` / runtime selector probe 使用；
- 集中封装，不把私有 selector 散落到业务代码；
- 每个 macOS 更新运行 E2E；
- 不兼容时 fail closed。

## 当前 EDP core

现有纯 Swift core 已包含：

- aligned block reads；
- LBA4/LBA7 recognition；
- LBA11 device identity；
- LBA12 partition metadata；
- CRC32；
- password/key validation；
- SM4；
- encrypted partition translation；
- `EDPEncryptedPartitionReader`；
- 3,200 deterministic property/random cases + golden/negative tests。

## 当前未完成部分

完整块桥已经证明，但真实 EDP 数据路径还需要接入：

```text
real EDP USB
  -> Swift EDP block translation
  -> macFUSE volume.raw
  -> DiskImages2
  -> existing native filesystem
  -> Finder
```

下一阶段优先：

1. 把 PoC 内存 backing 替换成真实 EDP decrypted block view；
2. 先完成真实盘只读 Finder mount；
3. 再实现安全 partial-write / read-modify-write / flush；
4. 完成 SwiftUI 设备发现、密码输入和 mount lifecycle；
5. 做 macFUSE FSKit 首次安装/批准的一键引导。

## 永久 PoC

```text
.github/workflows/macfuse-diskimages2-poc.yml
native/EDPFSKitPoC/Tools/DiskImages2Attach.m
native/EDPFSKitPoC/Tools/probe-macfuse-diskimages2.sh
```

完整架构、证据边界和后续实施顺序见 [`docs/STATUS.md`](docs/STATUS.md)。
