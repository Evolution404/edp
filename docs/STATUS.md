# EDP USB Vault — macOS 26 当前状态与唯一实施方案

更新时间：2026-08-26
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

## 3. 已完成的三级架构/边界证明

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
original proof run: 32851503960
latest combined run: 32865857756
runner:             macOS 26.5.2 (25F84), arm64
Xcode:              26.6
macFUSE:            5.3.3
libfuse:            2.9.9
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

### 3.3 产品式 real-device unlock -> FUSE 边界：已完成

GitHub Actions run `32865857756` 新增了独立 gate，使用仓库中已采集的真实 Lexar LBA11/LBA12 metadata 构造只读 sparse raw-device fixture，并走与产品一致的入口：

```text
real LBA11/LBA12 fixture
+ actual VID/PID/device size metadata
+ password bytes from inherited FD
  -> EDPFileRawDevice(declaredSizeBytes:)
  -> EDPReadOnlyUnlock
  -> edp_ro_open_device
  -> EDPEncryptedReadOnlyBlockDevice
  -> EDPReadOnlyFuseBridge --device
  -> macFUSE backend=fskit
  -> volume.raw
```

关键结果：

```text
RESULT=EDP_DEVICE_MODE_BRIDGE_BUILT
RESULT=EDP_REAL_METADATA_FIXTURE_READY
RESULT=EDP_DEVICE_MODE_WRONG_PASSWORD_REJECTED
RESULT=EDP_DEVICE_UNLOCK_EXPOSED_DESCRIPTOR_SIZE_OK
RESULT=EDP_DEVICE_MODE_RANDOM_READS_OK
RESULT=EDP_DEVICE_PASSWORD_FD_TRANSPORT_OK
RESULT=EDP_PRODUCT_UNLOCK_FUSE_DEVICE_MODE_OK
```

该 gate 确认真实 type-2 descriptor 的逻辑尺寸保持为 `118477684736` bytes，没有因 NTFS boot-sector 自报尺寸少 1 sector 而被擅自归一化。

密码不进入 argv/env；FUSE C 边界只接收 password FD，读取后立即清零临时 buffer。derived file key 仍然只存在于 Swift unlock/core 内部，不跨越 C ABI。

这一级**不是**真实 U 盘 Finder mount：sparse fixture 只用于验证真实 metadata + 产品 unlock API + secret transport + FUSE 边界。真实 encrypted partition plaintext 正确性由物理采集证据和 synthetic crypto E2E 分别覆盖。

### 3.4 Swift EDP crypto read/write 路径：已完成

2026-08-26 本机 macOS 26.6.2 完成新的永久回归：

```text
native ExFAT whole-disk image
  -> SM4 ciphertext
  -> writable EDPFileRawDevice
  -> serialized SM4 partial-block read-modify-write
  -> EDPEncryptedReadWriteBlockDevice
  -> edp_rw_* C ABI
  -> macFUSE FSKit writable volume.raw
  -> DiskImages2 Media Read-Only: No
  -> native filesystem create/write/sync
  -> eject + FUSE process exit
  -> restart + reattach + SHA-256 verification
```

关键结果：

```text
RESULT=SWIFT_NATIVE_ENCRYPTED_WRITER_OK
RESULT=EDP_CRYPTO_READWRITE_FUSE_READY
RESULT=NATIVE_EXFAT_MOUNTED_READWRITE_THROUGH_EDP_CRYPTO
RESULT=EDP_ENCRYPTED_WRITE_CHANGED_CIPHERTEXT
RESULT=EDP_FILESYSTEM_WRITE_SURVIVES_FULL_REMOUNT
RESULT=EDP_CRYPTO_DISKIMAGES2_NATIVE_FS_READWRITE_E2E_OK
```

这证明 EDP 自己负责的可写透明块层已经闭环。具体 NTFS 写入仍由外部 NTFS driver 决定；不能用 ExFAT 的通过替代 NTFS driver gate。

本机 iBoysoft 4.5 实测：DiskImages2 发布的介质为 `Media Read-Only: No`，但 iBoysoft 自动挂载和显式 `-o rw` 都返回 `Volume Read-Only: Yes`。测试因此在创建真实 NTFS 文件前 fail closed。物理 `/dev/rdisk6` 另受 `root:operator 0640` 限制，产品 helper 必须先 `O_RDWR` 打开并继承 `/dev/fd/N`，不能让普通 App 直接打开 raw path。

## 4. 证据边界：真实 EDP crypto 已证明，Finder 实盘挂载仍待 macOS 26

2026-08-25 已在真实物理 EDP U 盘上完成只读采集，并用新的统一 `EDPReadOnlyUnlock` 产品路径再次回归成功。

真实设备证据：

```text
BSD disk:                 disk5
raw device:               /dev/rdisk5
USB VID/PID:              21c4:0cd1
device size:              124736503808 bytes
device ID:                disk&ven_lexar&prod_usb_flash_drive
selected partition type:  2
partition start sector:   20480
partition size:           118477684736 bytes
captured decrypted bytes: 1048576
secrets written:          false
```

真实解密后的数据头是有效 NTFS volume boot sector：

```text
EB 52 90 "NTFS    "
bytes/sector    = 512
sectors/cluster = 8
cluster size    = 4096
MFT LCN         = 786432
boot signature  = 55 AA
```

因此以下证据链已经成立：

```text
real EDP USB
  -> actual VID/PID/device size
  -> actual LBA11 device identity
  -> actual LBA12 decode
  -> actual password validation
  -> actual derived file key
  -> actual encrypted data partition
  -> EDPReadOnlyUnlock
  -> EDPEncryptedPartitionReader
  -> EDPEncryptedReadOnlyBlockDevice
  -> valid native NTFS plaintext
```

当前仍**不能**写成“真实 EDP U 盘已在 Finder 挂载成功”，因为实体证据机是 macOS 15.7.9，而产品级 `macFUSE backend=fskit -> Private DiskImages2` 链只在 macOS 26+ 继续验证。不要为了最后一步重新开启 macOS 15 FSKit 兼容研究。

唯一剩余 read-only runtime gate 是在 **macOS 26+ 且插有同一真实 EDP U 盘的机器**上完成：

```text
real EDPEncryptedReadOnlyBlockDevice
  -> macFUSE FSKit volume.raw
  -> DiskImages2 read-only diskN
  -> Apple native NTFS
  -> Finder read
```

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

同一文件现在还包含统一产品解锁边界：

```text
EDPReadOnlyUnlockRequest
  vidHex
  pidHex
  deviceSizeBytes
  passwordBytes
  partitionType

EDPReadOnlyUnlock.unlock(raw:request:)
  -> EDPUnlockedReadOnlyVolume
  -> EDPEncryptedReadOnlyBlockDevice
```

真实 `disk5` 已通过该工厂成功完成 LBA11/LBA12、密码校验、file-key 派生和 NTFS 数据头解密。公开结果不暴露 derived file key。

它不 import FSKit，不 import macFUSE，不 import DiskImages2，也不知道 exFAT/APFS/FAT。

现已加入独立的 `EDPBlockWritable`、`EDPEncryptedReadWriteBlockDevice` 和 `EDPReadWriteUnlock`；只读 API 保留且继续独立回归。

### 5.3 raw storage adapter

`Extension/EDPFileRawDevice.swift`：

- 显式 read-only / read-write open mode；
- `fstat` size；
- 对 `/dev/rdiskN` 支持由设备发现层提供可信 `declaredSizeBytes`，不依赖 device node 的 `st_size`；
- exact `pread`；
- exact `pwrite`；
- `fsync` + macOS `F_FULLFSYNC` durability boundary；
- position-independent，可支持并发随机读取；
- 严格 bounds/EOF/error handling。

真实 `/dev/rdiskN` 接入时应继续保持同一 `EDPRawReadable` 边界，而不是把 FUSE/DiskImages2 逻辑塞进 crypto core。

### 5.4 macFUSE boundary

当前 E2E 使用：

```text
Tools/EDPReadOnlyBlockCBridge.swift
Tools/EDPReadOnlyFuseBridge.c
Tools/EDPReadWriteBlockCBridge.swift
Tools/EDPReadWriteFuseBridge.c
```

C 代码只承担 libfuse callback ABI；所有 SM4 和 offset expansion 仍在 Swift core 中完成。不要在 C 层复制 crypto 实现。

Swift C bridge 现同时保留：

```text
edp_ro_open         synthetic/manual-key regression API
edp_ro_open_device  real-device product-unlock API
edp_ro_size
edp_ro_read
edp_ro_close
```

`edp_ro_open_device` 接收 raw path、VID/PID、declared device size、进程内密码 bytes 和 partition type，并调用统一 `EDPReadOnlyUnlock`；derived file key 不跨越该 ABI。

FUSE executable 现同时支持：

```text
synthetic/manual-key:
EDPReadOnlyFuseBridge <cipher.img> <32-hex-key> <mountpoint>

product/real-device:
EDPReadOnlyFuseBridge --device <raw-device> <vid> <pid> <device-size> <partition-type> <password-fd> <mountpoint>
```

产品模式的密码只通过已继承 FD 传入；不放 argv/env，不由 C 层派生或暴露 file key。C 临时 password buffer 在调用 Swift ABI 后立即 zeroize。

可写 ABI 保持独立命名空间：

```text
edp_rw_open
edp_rw_open_device
edp_rw_size
edp_rw_read
edp_rw_write
edp_rw_sync
edp_rw_close
```

可写 FUSE bridge 提供 `write`、`flush`、`fsync`，退出前再次同步。真实 raw device 必须由 privileged helper 以 `O_RDWR` 打开，并将继承的 `/dev/fd/N` 作为 `--device` 的 raw path；密码仍单独走 password FD。

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

macFUSE block filesystem 本身保持极小：

```text
/
└── volume.raw
```

只读 bridge 继续只提供 size / open / random read。可写 bridge 在同一最小 namespace 上额外提供 random write / flush / fsync，且不包含任何具体文件系统语义。

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

### 8.3 real-metadata 产品 unlock -> FUSE gate

同一 workflow 现在先运行：

```text
native/EDPFSKitPoC/Tools/probe-edp-device-unlock.sh
```

最终 marker：

```text
RESULT=EDP_PRODUCT_UNLOCK_FUSE_DEVICE_MODE_OK
```

该 gate 必须持续验证：

- 真实 LBA11/LBA12 fixture 可通过统一产品 unlock；
- 错误密码 fail closed；
- password 只经 FD 进入 FUSE 进程；
- descriptor size 原样暴露，不修正真实 1-sector 差异；
- product-mode random read 可穿过 `edp_ro_open_device -> EDPEncryptedReadOnlyBlockDevice -> FUSE`。

这些 gate 必须覆盖任何对下列代码的修改：

- EDP crypto / partition reader；
- block abstraction；
- raw adapter；
- FUSE block bridge；
- DiskImages2 bridge；
- macFUSE/target macOS 版本变化。

现有 `Native Swift Fast Checks` 的 3,200 cases 与这些系统级 E2E 是不同证据层，不混算测试数量。

## 9. 下一步实施顺序

### P0 — 真实 EDP read-only Finder mount

当前 P0 已完成：

1. 真实 EDP U 盘 LBA11/LBA12 读取；
2. 真实 VID/PID/device size + 用户密码校验；
3. 真实 file key 派生；
4. 真实 type-2 encrypted partition 选择；
5. 真实 raw device -> `EDPReadOnlyUnlock` -> `EDPEncryptedPartitionReader`；
6. `EDPEncryptedReadOnlyBlockDevice` 真实 NTFS 明文读取；
7. `edp_ro_open_device` Swift/C ABI 导出；
8. macOS 26 CI 上真实 metadata fixture -> password FD -> `--device` FUSE product boundary 验证。

剩余动作只应在 macOS 26+ 实体机执行：

1. 用真实 `/dev/rdiskN` + VID/PID/device size + password FD 启动现有 `EDPReadOnlyFuseBridge --device`；
2. 用 DiskImages2 `--readonly` 发布 `/dev/diskN`；
3. 确认 `Media Read-Only: Yes`；
4. 让 Apple 原生 NTFS 实现识别并挂载；
5. Finder 打开真实文件并做 byte/hash 对照；
6. 正常 unmount/eject/FUSE teardown/key cleanup。

### P1 — 写支持

已完成：

1. `EDPBlockWritable` / `write(offset,data)` / `synchronize`；
2. SM4 partial-block read-modify-write；
3. crypto alignment / bounds；
4. concurrent read/write serialization；
5. `pwrite` / `fsync` / `F_FULLFSYNC`；
6. FUSE `write` / `flush` / `fsync`；
7. DiskImages2 writable media；
8. native filesystem metadata/data 写入和完整重挂载验证。

剩余 NTFS 产品 gate：

1. helper 以 `O_RDWR` 打开真实 raw device 并继承 FD；
2. iBoysoft（或另一受支持 NTFS driver）实际挂载为 `Volume Read-Only: No`；
3. 真实 EDP NTFS 小文件写入、sync、重挂载 hash 验证；
4. 拔盘、进程 crash、断电 fault tests；
5. 最后开放 Finder 正常写入。

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

截至 2026-08-26，已经形成五级证据：

1. macOS 26：`macFUSE FSKit -> Private DiskImages2 -> /dev/diskN -> Apple native filesystem` 块桥成立；
2. macOS 26：Swift `EDPEncryptedPartitionReader` 位于同一块桥中时，synthetic 整盘 SM4 ciphertext 可被 Apple 原生文件系统正确读取；
3. macOS 26：真实 Lexar LBA11/LBA12 metadata 可经 `edp_ro_open_device`、password FD 和 `EDPReadOnlyFuseBridge --device` 成功发布正确尺寸的 FSKit `volume.raw`，错误密码 fail closed；
4. 真实物理 EDP U 盘：真实 LBA11/LBA12、真实密码验证、真实 file key、真实 type-2 encrypted partition 已通过统一 `EDPReadOnlyUnlock` 解密为有效 NTFS block view。
5. macOS 26.6.2：可写 Swift crypto block、FUSE FSKit、DiskImages2 和原生文件系统写入闭环成立，ciphertext 变化且完整重挂载后文件 hash 一致。

因此 EDP 透明块层的读写实现已完成，仍不自行实现具体文件系统。当前剩余产品 gate 是 privileged helper 的真实 raw `O_RDWR` FD 交接，以及让受支持的 NTFS driver 真正返回 `Volume Read-Only: No` 后完成真实 EDP NTFS 写入/重挂载验证。本机 iBoysoft 4.5 当前强制只读，不能绕过该 gate 或误报成功。
