# EDP USB Vault — macOS 26 当前状态与唯一实施方案

更新时间：2026-08-25  
分支：`feat/macos26-native-fskit`

> 本文件是该分支唯一的状态、架构和后续实施交接文档。若 README、旧代码或历史结论与本文冲突，以本文和最新可复现实验证据为准。

## 1. 不可变产品约束

目标平台仅为 **macOS 26+**。

产品必须满足：

- 原生 Swift/SwiftUI App；
- EDP 层只负责 metadata、password/key、SM4 和 block translation；
- **不自行实现 exFAT/APFS/FAT/NTFS 等任何具体文件系统语义**；
- 解密后的块视图交回 macOS 原生磁盘和文件系统栈；
- 使用 macFUSE 5.x 的 **FSKit backend**；
- 不使用 macFUSE kernel backend；
- 不使用 `hdiutil` 作为产品 runtime bridge；
- 不使用 DriverKit / `IOUserBlockStorageDevice` entitlement；
- 不要求关闭 SIP、Reduced Security 或其他启动安全降级；
- 不要求 EDP App 自身拥有 Apple Developer Program 才能完成块桥；
- 不恢复 Rust/Tauri 或自研文件系统作为最终产品数据路径。

macOS 15.x 不再是产品目标。15.7.9 机器仅用于读取真实 EDP U 盘和采集经过审阅的真实 fixture/evidence。

## 2. 当前唯一产品架构

```text
physical EDP USB
  -> raw device
  -> LBA11/LBA12 / password validation / key derivation
  -> Swift SM4 transparent block translation
  -> EDPBlockReadable / later EDPBlockDevice
  -> macFUSE 5.3.3, backend=fskit
  -> hidden FUSE mount / volume.raw
  -> Private DiskImages2
  -> AppleDiskImages / IOMedia
  -> /dev/diskN
  -> Disk Arbitration
  -> Apple native filesystem implementation
  -> Finder
```

职责边界：

1. **EDP core 只认识 offset + length + encrypted bytes。**
2. **macFUSE 只把逻辑块视图暴露为一个 random-access regular file。**
3. **Private DiskImages2 负责 regular file -> IOMedia/BSD disk。**
4. **Apple 原生文件系统负责分区、目录、文件和具体 filesystem metadata。**
5. EDP 项目中不得新增 exFAT cluster/FAT/directory parser 作为产品依赖。

## 3. 已完成的两级架构证明

### 3.1 结构性块桥 E2E：已完成

GitHub Actions：

```text
workflow: macFUSE + DiskImages2 PoC
run:      32848875297
runner:   macOS 26.5.2 (25F84), arm64
Xcode:    26.6
macFUSE:  5.3.3
libfuse:  2.9.9
```

测试链：

```text
128 MiB random-access memory backing
  -> macFUSE FSKit volume.raw
  -> Private DiskImages2
  -> /dev/disk8
  -> Apple native ExFAT format/mount
  -> real file write/read
  -> unmount/eject
```

关键结果：

```text
RESULT=MACFUSE_FSKIT_BACKING_READY
RESULT=DISKIMAGES2_ATTACH_OK
DI_BSD_NAME=disk8
RESULT=DISKIMAGES2_CREATED_BLOCK_DEVICE
RESULT=NATIVE_EXFAT_FORMAT_OK
RESULT=NATIVE_EXFAT_MOUNT_READ_WRITE_OK
RESULT=DISKIMAGES2_TEARDOWN_OK
RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK
```

证明：macFUSE FSKit regular file 可以被 Private DiskImages2 发布成真实 BSD disk，随后 Apple 原生文件系统正常工作。该 runtime PoC 没有调用 `hdiutil`。

### 3.2 Swift EDP crypto read path E2E：已完成

GitHub Actions：

```text
workflow: EDP Crypto + DiskImages2 Read-Only E2E
run:      32851503960
runner:   macOS 26.5.2 (25F84), arm64
Xcode:    26.6
macFUSE:  5.3.3
libfuse:  2.9.9
```

这一级不再使用“直接返回明文的内存 backing”。测试先创建一个正常的原生 exFAT raw image，再把整个 128 MiB image 用现有 Swift `EDPSM4` 加密。随后实际读取路径为：

```text
cipher.img
  -> EDPFileRawDevice (pread)
  -> EDPEncryptedPartitionReader
  -> EDPEncryptedReadOnlyBlockDevice
  -> Swift @_cdecl read boundary
  -> libfuse / macFUSE backend=fskit
  -> volume.raw
  -> Private DiskImages2 --readonly
  -> /dev/disk8, Media Read-Only = Yes
  -> Apple native filesystem
  -> proof.txt + 4 MiB payload.bin
```

关键成功标记：

```text
RESULT=EDP_SWIFT_C_SYMBOLS_EXPORTED
RESULT=EDP_CRYPTO_BRIDGE_TOOLS_BUILT
RESULT=NATIVE_FILESYSTEM_FIXTURE_PREPARED
ENCRYPTED_DISK_BYTES=134217728
RESULT=EDP_SM4_DISK_IMAGE_ENCRYPTED
RESULT=ENCRYPTED_BACKING_DIFFERS_FROM_PLAINTEXT
RESULT=EDP_CRYPTO_FUSE_BACKING_READY
RESULT=EDP_ENCRYPTED_READER_RANDOM_WINDOWS_MATCH
RESULT=DISKIMAGES2_READONLY_SELECTOR_FOUND
RESULT=DISKIMAGES2_READONLY_ATTACH_OK
DI_BSD_NAME=disk8
RESULT=DISKIMAGES2_READONLY_BSD_DEVICE_CONFIRMED
RESULT=EDP_DECRYPTED_VIEW_PUBLISHED_AS_BSD_DISK
RESULT=APPLE_NATIVE_FILESYSTEM_READS_THROUGH_EDP_CRYPTO_OK
RESULT=EDP_READONLY_BLOCK_VIEW_ENFORCED
RESULT=EDP_CRYPTO_DISKIMAGES2_TEARDOWN_OK
RESULT=EDP_CRYPTO_MACFUSE_DISKIMAGES2_NATIVE_FS_READ_E2E_OK
```

DiskImages2 发布后的系统证据：

```text
Device Node:       /dev/disk8
Protocol:          Disk Image
Disk Size:         134217728 Bytes
Device Block Size: 512 Bytes
Media Read-Only:   Yes
Virtual:           Yes
```

测试还对非 16-byte 对齐窗口做了 plaintext vs decrypted FUSE view 比较：

```text
(offset=0,                  length=4096)
(offset=17,                 length=8191)
(offset=65531,              length=7777)
(offset=3 MiB + 5,          length=65519)
```

全部一致。

原生文件系统实际读取的 4 MiB payload：

```text
expected SHA-256 = be3fe57d3683161305fa72d30cb09a2d2621c60e420961ce516f56358b365a79
actual   SHA-256 = be3fe57d3683161305fa72d30cb09a2d2621c60e420961ce516f56358b365a79
```

同时 `touch` 写入被拒绝，证明当前 milestone 确实保持 read-only。

### 这一级证明了什么

现在已经不是“桥接结构理论可行”，而是：

> **现有 Swift `EDPEncryptedPartitionReader` 的随机解密结果，可以通过 macFUSE FSKit + Private DiskImages2 被 Apple 原生文件系统当作真实只读磁盘读取。**

因此产品不需要、也不应开发任何 exFAT 实现。

## 4. 证据边界：仍不能冒充真实 EDP U 盘成功

上述第二级 E2E 使用的是：

- macOS 原生创建的测试 raw filesystem image；
- deterministic test SM4 key；
- 使用真实产品代码 `EDPSM4` 加密；
- 使用真实产品代码 `EDPEncryptedPartitionReader` 解密。

它**不是**真实物理 EDP U 盘的数据区 cipher/plain pair，也没有在 CI 中使用真实 LBA11/LBA12 派生出来的 file key。

因此当前不能写成“真实 EDP U 盘已在 Finder 挂载成功”。

下一唯一 read-only runtime gate 是：

```text
real EDP USB
  -> actual LBA11/LBA12
  -> actual password validation
  -> actual derived file key
  -> actual encrypted data partition
  -> EDPEncryptedPartitionReader
  -> macFUSE FSKit volume.raw
  -> DiskImages2 read-only diskN
  -> Apple native filesystem
  -> Finder read
```

这一步通过后，read-only 产品数据路径才算闭环。

## 5. 当前实现模块

### 5.1 纯 Swift EDP core

已有：

- aligned window / exact raw read；
- LBA4/LBA7 recognition；
- LBA11 device identity；
- LBA12 decode / partition descriptor；
- CRC32；
- password/key validation；
- SM4 encrypt/decrypt；
- arbitrary unaligned encrypted partition reads；
- `EDPEncryptedPartitionReader`。

已有 deterministic/property/random coverage：**3,200 cases**，另有 golden/negative vectors。

### 5.2 新增 filesystem-agnostic block abstraction

`Extension/EDPBlockDevice.swift`：

```text
EDPBlockReadable
  sizeBytes
  read(offset,length)
```

`EDPEncryptedReadOnlyBlockDevice` 只是现有 `EDPEncryptedPartitionReader` 的薄适配层。

它不 import FSKit，不 import macFUSE，不 import DiskImages2，也不知道 exFAT/APFS/FAT。

写接口暂不加入，直到真实 EDP read-only mount 证明完成。

### 5.3 raw storage adapter

`Extension/EDPFileRawDevice.swift`：

- `O_RDONLY | O_CLOEXEC`；
- `fstat` size；
- exact `pread`；
- position-independent，可支持并发随机读取；
- 严格 bounds/EOF/error handling。

真实 `/dev/rdiskN` 接入时应继续保持同一 `EDPRawReadable` 边界，而不是把 FUSE/DiskImages2 逻辑塞进 crypto core。

### 5.4 macFUSE boundary

当前 E2E 使用：

```text
Tools/EDPReadOnlyBlockCBridge.swift
Tools/EDPReadOnlyFuseBridge.c
```

C 代码只承担 libfuse callback ABI；所有 SM4 和 offset expansion 仍在 Swift core 中完成。不要在 C 层复制 crypto 实现。

### 5.5 Private DiskImages2 bridge

集中在：

```text
Tools/DiskImages2Attach.m
```

当前已经验证两种 runtime contract：

可写结构 PoC：

```text
DIAttachParams initWithURL:error:
DiskImages2 attachWithParams:handle:error:
DIDeviceHandle BSDName
```

只读产品里程碑：

```text
DICommonAttach diskImageAttach:readOnly:autoMount:BSDName:error:
```

后者成功发布 `Media Read-Only: Yes` 的 BSD device。

## 6. Private DiskImages2 风险边界

DiskImages2 是 private API，因此必须：

- `dlopen` 动态加载；
- 启动时检查 class/selector；
- 私有 selector 只存在于单一 bridge module；
- 每个 macOS 目标版本/系统更新运行 E2E；
- 不兼容时 fail closed；
- 不根据 selector 名称猜测调用签名；新增调用必须先做独立 runtime proof；
- 不把 hosted-runner 成功解读为 Apple 的公开兼容承诺。

当前 macOS 26.5.2 hosted runner 上，普通测试 executable 无自定义 private entitlement 即可完成 DiskImages2 attach。该事实是 runtime evidence，不是公开 API 保证。

## 7. macFUSE 使用边界

产品仅使用：

```text
macFUSE 5.x
backend=fskit
```

禁止：

- macFUSE kernel backend；
- kext data path；
- Reduced Security；
- 关闭 SIP；
- `/sbin/mount -F` 旧路径。

macFUSE filesystem 本身保持极小：

```text
/
└── volume.raw
```

它只提供 size / open / random read；read-only milestone 不提供 write callback。

## 8. 永久 CI gates

### 8.1 结构性块桥

```text
.github/workflows/macfuse-diskimages2-poc.yml
```

最终 marker：

```text
RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK
```

### 8.2 EDP crypto read-only 块桥

```text
.github/workflows/edp-crypto-diskimages2-readonly.yml
```

最终 marker：

```text
RESULT=EDP_CRYPTO_MACFUSE_DISKIMAGES2_NATIVE_FS_READ_E2E_OK
```

这条 gate 必须覆盖任何对下列代码的修改：

- EDP crypto / partition reader；
- block abstraction；
- raw adapter；
- FUSE block bridge；
- DiskImages2 bridge；
- macFUSE/target macOS 版本变化。

现有 `Native Swift Fast Checks` 的 3,200 cases 与这两个系统级 E2E 是不同证据层，不混算测试数量。

## 9. 下一步实施顺序

### P0 — 真实 EDP read-only Finder mount

当前 P0 的“通用 crypto block bridge”部分已经完成。

接下来只做真实设备接入：

1. 从真实 EDP U 盘读取 LBA11/LBA12；
2. 用真实 VID/PID/device size 和用户密码得到真实 file key；
3. 选择真实 encrypted partition descriptor；
4. 将真实 raw device 交给 `EDPEncryptedPartitionReader`；
5. 以 `EDPEncryptedReadOnlyBlockDevice` 暴露给现有 FUSE bridge；
6. 用 DiskImages2 `--readonly` 发布 `/dev/diskN`；
7. 要求 Apple 原生文件系统自动识别；
8. Finder 打开真实文件并对已知 fixture 做 byte/hash 对照；
9. 正常 unmount/eject/FUSE teardown/key cleanup。

### P1 — 写支持

真实 read-only 闭环之前不实现。

之后再增加：

1. `EDPBlockWritable` / `write(offset,data)` / `flush`；
2. SM4 partial-block read-modify-write；
3. sector/block alignment；
4. concurrent read/write serialization；
5. fsync / DiskImages2 eject 顺序；
6. filesystem metadata 写入；
7. 拔盘、进程 crash、断电 fault tests；
8. 最后才开放 Finder 正常写入。

### P2 — 产品化 App

- SwiftUI 设备发现；
- 密码输入与 key 生命周期；
- macFUSE FSKit 首次安装/批准引导；
- 自动识别/解锁/mount；
- DiskImages2 capability probe；
- 安全 eject；
- key zeroization；
- 一键安装体验。

## 10. 明确废弃的方向

不再继续：

- 自研 exFAT reader/writer；
- 通用 filesystem namespace / `FSVolume` 产品实现；
- 自研 FSKit filesystem extension 作为产品主路径；
- 假想 FSKit module stacking；
- DriverKit `IOUserBlockStorageDevice`；
- macFUSE kernel backend；
- `hdiutil` runtime bridge；
- macOS 15 产品兼容；
- Rust/Tauri 最终产品架构；
- 常驻 helper daemon 作为必需数据路径。

旧 Native FSKit skeleton 可以暂时作为历史/对照研究代码存在，但不得继续驱动产品架构。

## 11. 当前结论

截至 2026-08-25，已经通过两个独立 macOS 26 E2E 证明：

1. `macFUSE FSKit -> Private DiskImages2 -> /dev/diskN -> Apple native filesystem` 的块桥成立；
2. 现有 Swift `EDPEncryptedPartitionReader` 可以位于这条块桥的数据路径中，对整盘 SM4 ciphertext 做任意随机解密，并让 Apple 原生文件系统正确读取文件。

因此下一阶段不再研究具体文件系统，也不再研究“如何制造块设备”本身；**唯一 P0 工作是把同一条已经验证的 read-only block path 换成真实 EDP U 盘、真实 metadata、真实 derived key 和真实 encrypted data region。**
